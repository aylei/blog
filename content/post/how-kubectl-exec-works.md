---
title: "kubectl exec 是如何工作的"
date: 2019-03-03T11:29:51+08:00
lastmod: 2019-03-03T11:29:51+08:00
draft: true
keywords: ["kubernetes","kubectl"]
tags: ["kubernetes"]
categories: ["kubernetes"]
author: "alei"
toc: true
comment: true
autoCollapseToc: false
---

之前有一个同事问我 Kubernetes（以下称 k8s）的 web shell 是怎么实现的，本想找几篇资料给他，却发现没有比较合适的。正好之前面试时也被问到 `kubectl exec` 是怎么实现的，于是便总结成了一篇博客发上来。

# 引入

由于 k8s 的 web shell 有好多个实现，我们就针对最常用的 `kubectl exec` 来进行分析。下面是一条典型的 "远程登录 Pod" 命令：

```shell
$ kubectl exec -it {pod_name} -c {container_name} -- sh
```

"远程登录"这个说法当然很不准确，这条命令的准确含义是**在目标容器上执行 `sh` 命令, 并将当前进程的 STDIN 连接到远端进程, 同时声明当前的 STDIN 是一个 tty(terminal)**

有点绕？没关系，接下来我们就逐一说清楚。

# 远程执行命令

首先是**在目标容器上执行 `sh` 命令**

在我们输入上面那条 `kubectl exec` 命令之后，真正发生的事情是：

1. `kubectl` 进程向 `apiserver` 发起一个 `pod exec` 请求，请求内容是"我要到 A Pod 的 XX Container 上执行 XXXXX 命令"，此外还有一些参数来控制 exec 的细节行为，另外，这个请求(HTTP)比较特殊，会带上一个 `Upgrade` Header，请求 server 将连接升级到 SPDY;
2. `apiserver` 不能什么客都接，他得先做认证(Authentication)，通过请求中的 token 或证书看看你小子是谁，再做鉴权(Authorization)，通过 [RBAC](https://www.cncf.io/blog/2018/08/01/demystifying-rbac-in-kubernetes/) 看看你小子有没有权限"对 A Pod 做 exec 操作";
3. 假如 authn & authz 都通过，那 `apiserver` 会找到 Pod 的对应 node，然后以反向代理的形式，向对应 kubelet 发送一个 `GetExec` 请求，作为 exec 前的预备，请求内容同上。注意，这里的反向代理实现了 `Upgrade` 兼容的逻辑，即假如代理的 server 将连接升级到新协议的话，这个反代也会把自己和 client 之间的连接升级到那个协议；
4. `kubelet` 收到 `GetExec` 请求后，会通过 [CRI](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-node/container-runtime-interface.md) 去请求容器运行时（比如 dockershime）的 `Exec`接口。这个请求通知容器运行时：请帮我准备一个 `exec` 的 endpoint

容器运行时收到请求后，会执行相应的 exec 准备动作，而接下来这些操作都是跟具体的 CRI 实现有关的。我们这里以 dockershim 为例，看一下典型的过程是怎样的: 

> dockershim 是一个 CRI 实现，它作为一个适配器层(shim, 垫片)，将 docker daemon 适配到 CRI 上

5. dockershim 收到 kubelet 的 `exec` 请求后，会为这条请求生成一个 unique token，并以 token 为 key，将请求存储到本地缓存中，最后构建一个 url `{host}/exec/{token}` 返回给 kubelet。
6. 接下来，kubelet 会根据 CRI 本身的配置，决定是将来自 apiserver 的连接 redirect 到容器运行时上，还是自己来代理连接。对于 dockershim，kubelet 会选择将连接重定向到 dockershim 上，重定向的地址就是刚刚返回的 `{host}/exec/{token}` 
7. apiserver 收到重定向，将请求重定向到 `{host}/exec/{token}` 上
8. dockershim 收到 `{host}/exec/{token}` 这个请求，你应该已经发现了，这个 url 其实正是 dockershim 在第五步中自己返回给 kubelet 的。接下来，dockershim 会根据 token 再拿出第五步中存进去的请求。可以看到，dockershim 是为了符合 CRI 的接口需要，才额外做了 5，6，7 这三步"脱裤子放屁"的操作，但从更高的层次来讲，维护接口层的统一性是更重要的
9. dockershim 拿出原始的 `exec` 请求之后要做的就是和 `docker exec` 指令一模一样的操作了：对 docker daemon 发起一个 `CreateExec` 调用，让 docker daemon 创建一个 exec endpoint
10. docker daemon 收到请求后，会按 `CreateExec` 中指定的命令内容，创建一个新进程，并加入到对应容器的 namespaces 中。接下来，docker daemon 会为这个进程创建一个 execID 并将这个 ID 返回给 dockershim
11. dockershim 根据 execID 向 docker daemon 发起 `StartExec` 请求，这个请求比较特殊，会带上一个 `Upgrade` header 请求将连接升级为 tcp
12. docker daemon 响应这个请求，并将连接切换到 tcp，并将这个连接的 输入 和 输出 绑定到容器的 STDIN 和 STDOUT/STDERR 或 PTY Slave 上
13. dockershim 收到响应，别忘了这时候 apiserver 还等着呢，于是乎

# --stdin 和 --tty

