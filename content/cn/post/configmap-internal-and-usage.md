---
title: "Kubernetes Configmap 配置更新: 原理解析与方案对比"
date: 2019-02-23T16:01:42+08:00
lastmod: 2019-02-23T16:01:42+08:00
draft: true
keywords: ["kubernetes","pod","configmap","热更新"]
tags: ["cloudnative","architecture"]
categories: ["kubernetes"]
contentCopyright: true
toc: true
comment: true
autoCollapseToc: false
---

Kubernetes 的应用过程中

# Pod 中的 Configmap 是如何自动更新的?

我们先看一下[官方文档](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/#mounted-configmaps-are-updated-automatically)中对 configmap 自动更新的描述：

> When a ConfigMap already being consumed in a volume is updated, projected keys are eventually updated as well. Kubelet is checking whether the mounted ConfigMap is fresh on every periodic sync. However, it is using its local ttl-based cache for getting the current value of the ConfigMap. As a result, the total delay from the moment when the ConfigMap is updated to the moment when new keys are projected to the pod can be as long as kubelet sync period + ttl of ConfigMaps cache in kubelet.

> **Note:** A container using a ConfigMap as a subPath volume will not receive ConfigMap updates.

事实上，除了 `ConfigMap` 之外，`Secret`，`DownwardAPI` 等类型的 volume 也都会自动更新。而更新机制正如文档中概括的：Kubelet 通过 SyncLoop 定时更新这些 volume，确保 volume 内容的最终一致性。

当然，这里面还有许多问题没有解答，比如更新的时间延迟具体由什么决定？Kubelet 是怎么知道 volume 里的内容是否需要变更的？假如更新前我往 `ConfigMap` 对应的 `volume` 里写了内容，更新后会被抹去吗？以及, 为什么 `subPath` 无法自动更新呢？

我也是一头雾水，不过，源码会告诉我们所有的答案。 

## 前置知识：Kubelet 控制循环简单介绍

即使你之前没有看过任何和 Kubernetes 设计与实现相关的内容也没关系，看下面这个伪代码：

```golang
for {
    current := getCurrentState() // 获取当前节点上 pod 的 *实际状态*
    desired := getDesiredState() // 获取当前节点上 pod 的 *期望状态*
    performActions(current, desired) // 执行一系列操作，让 *实际状态* 不断趋向于 *期望状态*
}
```

为什么我们要跑这样的控制循环呢？我们知道，kubernetes 的目标很简单，就是帮我们编排各种分布式对象。这个大任务会拆分给各个组件。分到 kubelet 这个劳工身上，他需要做好的事情就是把分配给自身节点的 Pod 管理好。而管理方式就是**控制循环**

举个例子，1 个 Pod-A 分配给了某个 kubelet，那这个 kubelet 的**期望状态**就是"1 个运行的Pod-A"，而实际状态却是 0 个，怎么办呢？启动一个 Pod-A 嘛。再换个角度，假如我们不做任何操作，kubelet 是不是就没事干了？当然不是， Pod 本身运行过程中就会出现各种各样的问题，比如说挂掉，这时的**实际状态**变成了 "1 个挂掉的Pod-A"，与**期望状态**不符，kubelet 就知道要重启它了。

> 各种 Controller, Operator 的设计模式也正是控制循环

因此，这个控制循环需要永远跑下去，不断地去驱动实际状态向期望状态转移。

当然，Kubelet 的职责其实是很重的，除了 Pod 之外，他还要管理好节点上存储卷(volume)、 网络等设备。因此除了最主要的 Pod 控制循环（我们称作 SyncLoop(代码)）之外，kubelet 还会针对这些对象也各自跑一个控制循环进行管理,如下图（引自 [@Harry Zhang](https://github.com/resouer) 的分享）：

![kubelet](http://ww1.sinaimg.cn/large/bf52b77fgy1g0gh7iszc5j21hc0u0q5s.jpg)

实际的 kubelet 架构远比上面讲得要复杂，但目前为止了解这些概念就足够读完这篇文章了。`ConfigMap` 等 volume 的更新正是在 `SyncLoop` 和 VolumeManager 的"控制循环"下协作完成的。

## ConfigMap volume 的工作原理

ConfigMap 的典型使用方式如下：

首先我们定义一个 `ConfigMap` 的 yaml 文件，apply 到 kubernetes。注意，根据 configmap 的设计，`data` 下的每一个 kv 对都应当代表**一个文件**，key 是文件名，value 则是文件内容。下面的 yaml 中我们就定义了两个"文件": config.yml 和 bootstrap.yml:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-config
data:
  config.yml: |-
    start-message: 'Hello, World!'
    log-level: INFO
  bootstrap.yml:
    listen-address: 127.0.0.1:8080
```

然后呢，我们会在自己的 Pod 模板里声明引用这个 `ConfigMap` 作为 volume，并将它挂载到某个目录下，供应用读取（注意缩进，`volumeMounts` 是容器的字段而 `volumes`是 Pod 的字段）：

```yaml
  volumeMounts:
    - mountPath: /etc/config
      name: config-volume
volumes:
  - configMap:
      name: test-config
    name: config-volume
```

启动容器之后，远程执行一下 `cat` 命令就可以验证我们的 `ConfigMap` 确确实实挂载到了目标容器中：

```bash
kubectl exec my-pod cat /etc/config/config.yml
kubectl exec my-pod cat /etc/config/bootstrap.yml
```

**这是怎么做到的呢？**

回到控制循环，在 Pod 的控制循环中，我们想要启动这个 Pod 需要先规规矩矩地按照 yaml 声明把 test-config 作为一个 volume 绑定到节点上（Attach），再挂载到容器里（Mount）。但问题是这个事情并不归我 Pod 的控制循环管，因此在 Pod 的控制循环中，我们只能等待 volumeManager 的控制循环去完成这个操作。

volumeManager 的控制循环异曲同工，也是从实际状态到期望状态趋近的思路，具体实现上有两个单独的循环：

* `desiredStateOfWorld`(代码): 负责收集节点上 volume 的期望状态
* `reconcile`(代码): 维护 volume 的实际状态，与期望状态进行对比，执行 volume 操作

具体来说，对于刚刚的挂载例子而言，`desiredStateOfWorld` 会收集到"有一个 Pod 需要挂载一个类型为 ConfigMap 的 volume" 这样的期望状态，而 `reconcile` 逻辑就会拿到这个状态去做 Attach(假如必要) 和 Mount 操作。

**这里又有一个问题，ConfigMap 显然不是一个传统意义上的 "存储介质"，为什么 kubelet 可以把它作为 volume 呢？**

其实，volumeManager 在针对 volume 做 Attach 和 Mount 操作时，都是委托给 volumePlugin 完成的。`ConfigMapPlugin`(代码) 清楚地知道该怎么初始化一个 `ConfigMap` 类型的 volume 并把它挂载到容器的一个目录上，这也正是 kubernetes "兼容并包" 的插件机制的一个缩影。

当然，`Secret`、`DownwardAPI` 这些 volume 也都有自己对应的插件，并且走的是同样的控制流程。

## ConfigMap 插件

最后就是 `ConfigMapPlugin` 究竟干了什么。首先 `ConfigMap` 只是一个 API 对象，本身是和存储没有啥关系的。我们怎么又搞出了一个 volume 来呢？

我们先聊聊另一种更简单的 volume 类型：`EmptyDir`

`EmptyDir` 是一个跟 Pod 拥有相同生命周期的临时目录，它的所有内容都不会持久化。那有什么用呢？别忘了 Pod 中容器的 volume 是共享的，`EmptyDir` 可以作为一个共有目录在 Pod 中的多个容器间传递文件。

TODO

这里的办法就是先以 `EmptyDir` 的是形式创建并初始化目录，并在目录中写入 `ConfigMap` 所定义的文件。

接下来是热更新。还记得 Kubelet 的 Pod 控制循环吗？Pod 控制循环会定时对 Pod 的状态进行同步（Sync），默认的时间间隔是 10 秒，而在同步时有一个特殊的操作就是会通知 volumeManager 去重新处理这个 Pod。可是这些 volume 都运行得好好的，有啥可处理的呢？

`ConfigMap` 就是一种需要重新处理的 volume，因为它的内容可能会发生变化，同理，`Secret` 和 `DownwardAPI` 这些自然也需要。那么，volume 如何告诉 volumeManager 自己是否需要重新处理呢？聪明的你应该已经想到了，还是交给 volumePlugin 来处理。volumePlugin 提供了一个方法 `requireRemount()` 来告诉 volumeManager 自己是否需要在 Pod 同步时重新做 Mount。对于 `ConfigMap`，这个方法的返回值是写死的 `true`。

这下事情就清楚了，`ConfigMap` 其实是在 `EmptyDir` 的基础上写入了 `ConfigMap` 中定义的配置文件，并且每次 Pod 同步时，它所有挂载的 `ConfigMap` volume 都会重新进行一次 Mount 操作，以此来保证 `ConfigMap` 的更新。

## 更新与 Atomic Write

如何判断是否更新：对比整个 dir
Atomic Write：写入 "以当前时间戳命名的目录", 软链接 ..data_tmp 到这个目录，用 rename 直接把 ..data_tmp 重命名到 ..data (所有的文件都软链接 ..data 中的文件)
为什么 subPath 没用：

