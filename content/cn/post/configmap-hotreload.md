---
title: "Kubernetes Pod 中的 ConfigMap 配置更新"
date: 2019-02-24T20:04:16+08:00
lastmod: 2019-02-24T20:04:16+08:00
draft: false
keywords: ["configmap", "kubernetes", "hot-reload"]
tags: ["kubernetes"]
categories: ["kubernetes"]
toc: true
comment: true
autoCollapseToc: false
---

业务场景里经常会碰到配置更新的问题，在 "[GitOps](https://www.weave.works/blog/gitops-operations-by-pull-request)"模式下，Kubernetes 的 `ConfigMap` 或 `Secret` 是非常好的配置管理机制。但是，Kubernetes 到目前为止(1.13版本)还没有提供完善的 `ConfigMap` 管理机制，当我们更新 `ConfigMap` 或 `Secret` 时，引用了这些对象的 `Deployment` 或 `StatefulSet` 并不会发生滚动更新。因此，我们需要自己想办法解决配置更新问题，让整个流程完全自动化起来。

> GitOps 的大体来说就是使用 git repo 存储资源描述的代码(比如各类 k8s 资源的 yaml 文件)，再通过 CI 或控制器等手段保证集群状态与仓库代码的同步，最后通过 Pull Request 流程来审核,执行或回滚运维操作


> 这篇文章中的所有知识对 `Secret` 对象也是通用的，为了简明，下文只称 `ConfigMap`

# 概述

首先，我们先给定一个背景，假设我们定义了如下的 `ConfigMap`：

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
    listen-address: '127.0.0.1:8080'
```

这个 `ConfigMap` 的 `data` 字段中声明了两个配置文件，`config.yml` 和 `bootstrap.yml`，各自有一些内容。当我们要引用里面的配置信息时，Kubernetes 提供了两种方式：

* 使用 `configMapKeyRef` 引用 `ConfigMap` 中某个文件的内容作为 Pod 中容器的环境变量；
* 将所有 `ConfigMap` 中的文件写到一个临时目录中，将临时目录作为 volume 挂载到容器里，也就是 configmap 类型的 volume;

好了，假设我们有一个 `Deployment`，它的 Pod 模板中以引用了这个 `ConfigMap`。现在的问题是，**我们希望当 `ConfigMap` 更新时，这个 `Deployment` 的业务逻辑也能随之更新，有哪些方案？**

* 最好是在当 `ConfigMap` 发生变更时，直接进行热更新，从而做到不影响 Pod 的正常运行
* 假如无法热更新或热更新完成不了需求，就需要触发对应的 `Deployment` 做一次滚动更新

接下来，我们就探究一下不同场景下的几种应对方案

# 场景一：针对可以做热更新的容器，进行配置热更新

当 `ConfigMap` 作为 volume 进行挂载时，它的内容是会更新的。为了更好地理解何时可以做热更新，我们要先简单分析 `ConfigMap` volume 的更新机制:

更新操作由 kubelet 的 Pod 同步循环触发。每次进行 Pod 同步时（默认每 10 秒一次），Kubelet 都会将 Pod 的所有 `ConfigMap` volume 标记为"需要重新挂载(RequireRemount)"，而 kubelet 中的 volume 控制循环会发现这些需要重新挂载的 volume，去执行一次挂载操作。

在 `ConfigMap` 的重新挂载过程中，kubelet 会先比较远端的 `ConfigMap` 与 volume 中的 `ConfigMap` 是否一致，再做更新。要注意，"拿远端的 `ConfigMap`" 这个操作可能是有缓存的，因此拿到的并不一定是最新版本。

由此，我们可以知道，`ConfigMap` 作为 volume 确实是会自动更新的，但是它的更新存在延时，最多的可能延迟时间是:

**Pod 同步间隔(默认10秒) + ConfigMap 本地缓存的 TTL**

> kubelet 上 ConfigMap 的获取是否带缓存由配置中的 `ConfigMapAndSecretChangeDetectionStrategy` 决定

> 注意，假如使用了 `subPath` 将 ConfigMap 中的某个文件单独挂载到其它目录下，那这个文件是无法热更新的（这是 ConfigMap 的挂载逻辑决定的）

有了这个底，我们就明确了：

* 假如应用对配置热更新有实时性要求，那么就需要在业务逻辑里自己到 ApiServer 上去 watch 对应的 `ConfigMap` 来做更新。或者，干脆不要用 `ConfigMap`，换成 `etcd` 这样的一致性 kv 存储来管理配置；
* 假如没有实时性要求，那我们其实可以依赖 `ConfigMap` 本身的更新逻辑来完成配置热更新；

当然，配置文件更新完不代表业务逻辑就更新了，我们还需要通知应用重新读取配置进行业务逻辑上的更新。比如对于 Nginx，就需要发送一个 SIGHUP 信号量。这里有几种落地的办法。

## 热更新一：应用本身监听本地配置文件

假如是我们自己写的应用，我们完成可以在应用代码里去监听本地文件的变化，在文件变化时触发一次配置热更新。甚至有一些配置相关的第三方库本身就包装了这样的逻辑，比如说 [viper](https://github.com/spf13/viper)。

## 热更新二：使用 sidecar 来监听本地配置文件变更

Prometheus 的 Helm Chart 中使用的就是这种方式。这里有一个很实用的镜像叫做 [configmap-reload](https://github.com/jimmidyson/configmap-reload)，它会去 watch 本地文件的变更，并在发生变更时通过 HTTP 调用通知应用进行热更新。

但这种方式存在一个问题：Sidecar 发送信号（Signal）的限制比较多，而很多开源组件比如 Fluentd，Nginx 都是依赖 SIGHUP 信号来进行热更新的。主要的限制在于，kubernetes 1.10 之前，并不支持 pod 中的容器共享同一个 pid namespace，因此 sidecar 也就无法向业务容器发送信号了。而在 1.10 之后，虽然支持了 pid 共享，但在共享之后 pid namespace 中的 1 号进程会变成基础的 `/pause` 进程，我们也就无法轻松定位到目标进程的 pid 了。

当然了，只要是 k8s 版本在 1.10 及以上并且开启了 `ShareProcessNamespace` 特性，我们多写点代码，通过进程名去找 pid，总是能完成需求的。但是 1.10 之前就是完全没可能用 sidecar 来做这样的事情了。

## 热更新三：胖容器

既然 sidecar 限制重重，那我们只能回归有点"反模式"的胖容器了。还是和 sidecar 一样的思路，但这次我们通过把主进程和sidecar 进程打在同一个镜像里，这样就直接绕过了 pid namespace 隔离的问题。当然，假如允许的话，还是用上面的一号或二号方案更好，毕竟容器本身的优势就是轻量可预测，而复杂则是脆弱之源。

# 场景二：无法热更新时，滚动更新 Pod

无法热更新的场景有很多：

* 应用本身没有实现热更新逻辑，而一般来说自己写的大部分应用都不会特意去设计这个逻辑；
* 使用 `subPath` 进行 `ConfigMap` 的挂载，导致 `ConfigMap` 无法自动更新；
* 在环境变量或 `init-container` 中依赖了 `ConfigMap` 的内容；

最后一点额外解释一下，当使用 `configMapKeyRef` 引用 `ConfigMap` 中的信息作为环境变量时，这个操作只会在 Pod 创建时执行一次，因此不会自动更新。而 `init-container` 也只会运行一次，因此假如 `init-contianer` 的逻辑依赖了 `ConfigMap` 的话，这个逻辑肯定也不可能按新的再来一遍了。

当碰到无法热更新的时候，我们就必须去滚动更新 Pod 了。相信你一定想到了，那我们写一个 controller 去 watch `ConfigMap` 的变更，watch 到之后就去给 `Deployment` 或其它资源做一次滚动更新不就可以了吗？没错，但就我个人而言，我更喜欢依赖简单的东西，因此我们还是从简单的方案讲起。

## Pod 滚动更新一：修改 CI 流程

这种办法异常简单，只需要我们写一个简单的 CI 脚本：给 `ConfigMap` 算一个 Hash 值，然后作为一个环境变量或 Annotation 加入到 Deployment 的 Pod 模板当中。

举个例子，我们写这样的一个 Deployment yaml 然后在 CI 脚本中，计算 Hash 值替换进去：

```yaml
...
spec:
  template:
    metadata:
      annotations:
        com.aylei.configmap/hash: ${CONFIGMAP_HASH}
...
```

这时，假如 `ConfigMap` 变化了，那 Deployment 中的 Pod 模板自然也会发生变化，k8s 自己就会帮助我们做滚动更新了。另外，如何 `ConfigMap` 不大，直接把 `ConfigMap` 转化为 JSON 放到 Pod 模板中都可以，这样做还有一个额外的好处，那就是在排查故障时，我们一眼就能看到这个 Pod 现在关联的 ConfigMap 内容是什么。

## Pod 滚动更新二：Controller

还有一个办法就是写一个 Controller 来监听 `ConfigMap` 变更并触发滚动更新。在自己动手写之前，推荐先看看一下社区的这些 Controller 能否能满足需求：

* [Reloader](https://github.com/stakater/Reloader)
* [ConfigmapController](https://github.com/fabric8io/configmapcontroller)
* [k8s-trigger-controller](https://github.com/mfojtik/k8s-trigger-controller)

# 结尾

上面就是我针对 `ConfigMap` 和 `Secret` 热更新总结的一些方案。最后我们选择的是使用 sidecar 进行热更新，因为这种方式更新配置带来的开销最小，我们也为此主动避免掉了"热更新环境变量这种场景"。

当然了，配置热更新也完全可以不依赖 `ConfigMap`，Etcd + Confd, 阿里的 Nacos, 携程的 Apollo 包括不那么好用的 Spring-Cloud-Config 都是可选的办法。但它们各自也都有需要考虑的东西，比如 Etcd + Confd 就要考虑 Etcd 里的配置项变更怎么管理；Nacos, Apollo 这种则需要自己在 client 端进行代码集成。相比之下，对于刚起步的架构，用 k8s 本身的 `ConfigMap` 和 `Secret` 可以算是一种最快最通用的选择了。

## Reference

* [Facilitate ConfigMap rollouts / management](https://github.com/kubernetes/kubernetes/issues/22368)
* [Feature request: A way to signal pods](https://github.com/kubernetes/kubernetes/issues/24957)
* [Share Process Namespace between Containers in a Pod](https://kubernetes.io/docs/tasks/configure-pod-container/share-process-namespace/)
* [Configure a Pod to Use a ConfigMap](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/)
