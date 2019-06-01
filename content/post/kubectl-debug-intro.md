+++
title = "简化 Pod 故障诊断: kubectl-debug 介绍"
author = ["Wu Yelei"]
lastmod = 2019-06-01T22:24:59+08:00
categories = ["kubernetes"]
draft = false
weight = 2001
+++

## 背景 {#背景}

容器技术的一个最佳实践是构建尽可能精简的容器镜像。但这一实践却会给排查问题带来麻烦：精简后的容器中普遍缺失常用的排障工具，部分容器里甚至没有 shell (比如 `FROM scratch` ）。
在这种状况下，我们只能通过日志或者到宿主机上通过 docker-cli 或 nsenter 来排查问题，效率很低。Kubernetes 社区也早就意识到了这个问题，在 16 年就有相关的 Issue
[Support for troubleshooting distroless containers](https://github.com/kubernetes/kubernetes/issues/27140) 并形成了对应的 [Proposal](https://github.com/kubernetes/community/blob/master/contributors/design-proposals/node/troubleshoot-running-pods.md)。 遗憾的是，由于改动的涉及面很广，相关的实现至今还没有合并到 Kubernetes 上游代码中。而在
一个偶然的机会下（PingCAP 一面要求实现一个 kubectl 插件实现类似的功能），我开发了 [kubectl-debug](https://github.com/aylei/kubectl-debug): **通过启动一个安装了各种排障工具的容器，来帮助诊断目标容器** 。


## 工作原理 {#工作原理}

我们先不着急进入 Quick Start 环节。 `kubectl-debug` 本身非常简单，因此只要理解了它的工作原理，你就能完全掌握这个工具，并且还能用它做 debug 之外的事情。

我们知道，容器本质上是带有 cgroup 资源限制和 namespace 隔离的一组进程。因此，我们只要启动一个进程，并且让这个进程加入到目标容器的各种 namespace 中，这个进程就能
"进入容器内部"（注意引号），与容器中的进程"看到"相同的根文件系统、虚拟网卡、进程空间了——这也正是 `docker exec` 和 `kubectl exec` 等命令的运行方式。

现在的状况是，我们不仅要 "进入容器内部"，还希望带一套工具集进去帮忙排查问题。那么，想要高效管理一套工具集，又要可以跨平台，最好的办法就是把工具本身都打包在一个容器镜像当中。
接下来，我们只需要通过这个"工具镜像"启动容器，再指定这个容器加入目标容器的的各种 namespace，自然就实现了 "携带一套工具集进入容器内部"。事实上，使用 docker-cli 就可以实现这个操作：

```bash
export TARGET_ID=666666666
# 加入目标容器的 network, pid 以及 ipc namespace
docker run -it --network=container:$TARGET_ID --pid=container:$TARGET_ID --ipc=container:$TARGET_ID busybox
```

这就是 kubectl-debug 的出发点： **用工具容器来诊断业务容器** 。背后的设计思路和 sidecar 等模式是一致的：每个容器只做一件事情。

具体到实现上，一条 `kubectl debug <target-pod>` 命令背后是这样的：

{{< figure src="/arch-2.jpg" width="800px" >}}

步骤分别是:

1.  插件查询 ApiServer：demo-pod 是否存在，所在节点是什么
2.  ApiServer 返回 demo-pod 所在所在节点
3.  插件请求在目标节点上创建 `Debug Agent` Pod
4.  Kubelet 创建 `Debug Agent` Pod
5.  插件发现 `Debug Agent` 已经 Ready，发起 debug 请求（长连接）
6.  `Debug Agent` 收到 debug 请求，创建 Debug 容器并加入目标容器的各个 Namespace 中，创建完成后，与 Debug 容器的 tty 建立连接

接下来，客户端就可以开始通过 5，6 这两个连接开始 debug 操作。操作结束后，Debug Agent 清理 Debug 容器，插件清理 Debug Agent，一次 Debug 完成。效果如下图：

{{< figure src="/kube-debug.gif" width="800px" >}}


## 开始使用 {#开始使用}

Mac 可以直接使用 brew 安装:

```bash
brew install aylei/tap/kubectl-debug
```

所有平台都可以通过下载 binary 安装:

```bash
export PLUGIN_VERSION=0.1.1
# linux x86_64
curl -Lo kubectl-debug.tar.gz https://github.com/aylei/kubectl-debug/releases/download/v${PLUGIN_VERSION}/kubectl-debug_${PLUGIN_VERSION}_linux_amd64.tar.gz
# macos
curl -Lo kubectl-debug.tar.gz https://github.com/aylei/kubectl-debug/releases/download/v${PLUGIN_VERSION}/kubectl-debug_${PLUGIN_VERSION}_darwin_amd64.tar.gz

tar -zxvf kubectl-debug.tar.gz kubectl-debug
sudo mv kubectl-debug /usr/local/bin/
```

Windows 用户可以在 [Release 页面](https://github.com/aylei/kubectl-debug/releases/tag/v0.1.1) 进行下载。

下载完之后就可以开始使用 debug 插件:

```bash
kubectl debug target-pod --agentless --port-forward
```

> kubectl 从 1.12 版本之后开始支持从 PATH 中自动发现插件。1.12 版本之前的 kubectl 不支持这种插件机制，但也可以通过命令名 `kubectl-debug` 直接调用。

可以参考项目的 [中文 README](https://github.com/aylei/kubectl-debug/blob/master/docs/zh-cn.md) 来获得更多文档和帮助信息。


## 典型案例 {#典型案例}


### 基础排障 {#基础排障}

kubectl debug 默认使用 [nicolaka/netshoot](https://github.com/nicolaka/netshoot) 作为默认的基础镜像，里面内置了相当多的排障工具，包括：

使用 **iftop** 查看容器网络流量：

```bash
➜  ~ kubectl debug demo-pod

root @ /
 [2] 🐳  → iftop -i eth0
interface: eth0
IP address is: 10.233.111.78
MAC address is: 86:c3:ae:9d:46:2b
# (图片略去)
```

使用 **drill** 诊断 DNS 解析：

```bash
root @ /
 [3] 🐳  → drill -V 5 demo-service
;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 0
;; flags: rd ; QUERY: 1, ANSWER: 0, AUTHORITY: 0, ADDITIONAL: 0
;; QUESTION SECTION:
;; demo-service.	IN	A

;; ANSWER SECTION:

;; AUTHORITY SECTION:

;; ADDITIONAL SECTION:

;; Query time: 0 msec
;; WHEN: Sat Jun  1 05:05:39 2019
;; MSG SIZE  rcvd: 0
;; ->>HEADER<<- opcode: QUERY, rcode: NXDOMAIN, id: 62711
;; flags: qr rd ra ; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 0
;; QUESTION SECTION:
;; demo-service.	IN	A

;; ANSWER SECTION:

;; AUTHORITY SECTION:
.	30	IN	SOA	a.root-servers.net. nstld.verisign-grs.com. 2019053101 1800 900 604800 86400

;; ADDITIONAL SECTION:

;; Query time: 58 msec
;; SERVER: 10.233.0.10
;; WHEN: Sat Jun  1 05:05:39 2019
;; MSG SIZE  rcvd: 121
```

使用 **tcpdump** 抓包：

```bash
root @ /
 [4] 🐳  → tcpdump -i eth0 -c 1 -Xvv
tcpdump: listening on eth0, link-type EN10MB (Ethernet), capture size 262144 bytes
12:41:49.707470 IP (tos 0x0, ttl 64, id 55201, offset 0, flags [DF], proto TCP (6), length 80)
    demo-pod.default.svc.cluster.local.35054 > 10-233-111-117.demo-service.default.svc.cluster.local.8080: Flags [P.], cksum 0xf4d7 (incorrect -> 0x9307), seq 1374029960:1374029988, ack 1354056341, win 1424, options [nop,nop,TS val 2871874271 ecr 2871873473], length 28
  0x0000:  4500 0050 d7a1 4000 4006 6e71 0ae9 6f4e  E..P..@.@.nq..oN
  0x0010:  0ae9 6f75 88ee 094b 51e6 0888 50b5 4295  ..ou...KQ...P.B.
  0x0020:  8018 0590 f4d7 0000 0101 080a ab2d 52df  .............-R.
  0x0030:  ab2d 4fc1 0000 1300 0000 0000 0100 0000  .-O.............
  0x0040:  000e 0a0a 08a1 86b2 ebe2 ced1 f85c 1001  .............\..
1 packet captured
11 packets received by filter
0 packets dropped by kernel
```

访问目标容器的根文件系统：

容器技术(如 Docker）利用了 `/proc` 文件系统提供的 `/proc/{pid}/root/` 目录实现了为隔离后的容器进程提供单独的根文件系统（root filesystem）的能力（就是 `chroot` 一下）。当我们想要访问
目标容器的根文件系统时，可以直接访问这个目录：

```bash
root @ /
 [5] 🐳  → tail -f /proc/1/root/log_
Hello, world!
```

这里有一个常见的问题是 `free` `top` 等依赖 `/proc` 文件系统的命令会展示宿主机的信息，这也是容器化过程中开发者需要适应的一点（当然了，各种 runtime 也要去适应，比如臭名昭著的
[Java 8u121 以及更早的版本不识别 cgroups 限制](https://blog.softwaremill.com/docker-support-in-new-java-8-finally-fd595df0ca54) 问题就属此列）。


### 诊断 CrashLoopBackoff {#诊断-crashloopbackoff}

排查 `CrashLoopBackoff` 是一个很麻烦的问题，Pod 可能会不断重启， `kubectl exec` 和 `kubectl debug` 都没法稳定进行排查问题，基本上只能寄希望于 Pod 的日志中打印出了有用的信息。
为了让针对 `CrashLoopBackoff` 的排查更方便， `kubectl-debug` 参考 `oc debug` 命令，添加了一个 `--fork` 参数。当指定 `--fork` 时，插件会复制当前的 Pod Spec，做一些小修改，
再创建一个新 Pod：

-   新 Pod 的所有 Labels 会被删掉，避免 Service 将流量导到 fork 出的 Pod 上
-   新 Pod 的 `ReadinessProbe` 和 `LivnessProbe` 也会被移除，避免 kubelet 杀死 Pod
-   新 Pod 中目标容器（待排障的容器）的启动命令会被改写，避免新 Pod 继续 Crash

接下来，我们就可以在新 Pod 中尝试复现旧 Pod 中导致 Crash 的问题。为了保证操作的一致性，可以先 `chroot` 到目标容器的根文件系统中：

```bash
➜  ~ kubectl debug demo-pod --fork

root @ /
 [4] 🐳  → chroot /proc/1/root

root @ /
 [#] 🐳  → ls
 bin            entrypoint.sh  home           lib64          mnt            root           sbin           sys            tmp            var
 dev            etc            lib            media          proc           run            srv            usr

root @ /
 [#] 🐳  → ./entrypoint.sh
 # 观察执行启动脚本时的信息并根据信息进一步排障
```


## 结尾的碎碎念 {#结尾的碎碎念}

`kubectl-debug` 一开始只是 PingCAP 在面试时出的 homework，第一版完成在去年年底。当时整个项目还非常粗糙，不仅文档缺失，很多功能也都有问题：

-   不支持诊断 CrashLoopBackoff 中的 Pod
-   强制要求预先安装一个 Debug Agent 的 DaemonSet
-   不支持公有云（节点没有公网 IP 或公网 IP 因为防火墙原因无法访问时，就无法 debug）
-   没有权限限制，安全风险很大

而让我非常兴奋的是，在我无暇打理项目的情况下，隔一两周就会收到 Pull Request 的通知邮件，一直到今天，大部分影响基础使用体验的问题都已经被解决，
`kubectl-debug` 也发布了 4 个版本（ `0.0.1`, `0.0.2`, `0.1.0`, `0.1.1` )。尤其要感谢 [@tkanng](https://github.com/tkanng) , TA 在第一个 PR 时还表示之前没有写过 Go，
而在 `0.1.1` 版本中已经是这个版本绝大部分 feature 的贡献者，解决了好几个持续很久的 issue，感谢！

最后再上一下项目地址： <https://github.com/aylei/kubectl-debug>

假如在使用上或者对项目本身有任何问题，欢迎提交 issue，也可以在 [文章评论区](https://www.aleiwu.com/post/kubectl-debug-intro/#结尾的碎碎念) 或 [我的邮箱](mailto:rayingecho@gmail.com) 留言讨论。
