---
title: "kubectl exec 是如何工作的(刨根问底版)"
date: 2019-03-03T11:29:51+08:00
lastmod: 2019-03-03T11:29:51+08:00
draft: true
keywords: ["kubernetes","OS"]
tags: ["kubernetes"]
categories: ["kubernetes"]
author: "alei"
toc: true
comment: true
autoCollapseToc: false
---

之前有一次面试我被问到 `kubectl exec` 的原理是什么，当时就想着可以写到博客里。但要只是讲大体的流程，这篇博客就太水了，所以这次我们来一次"刨根问底"，乐趣为主，实战为辅~

> 前排提示：这篇文章介绍的内容通常来说并没有什么卵用

# 研究对象

首先我们来看一条用于 "远程登录 Pod" 的典型命令：

```shell
$ kubectl exec -it {pod_name} -c {container_name} -- sh
```

"远程登录"这个说法当然很不准确，这条命令的准确含义是**在目标容器上执行 `sh` 命令, 并将当前进程的 STDIN 连接到远端进程, 同时声明当前的 STDIN 是一个 tty(terminal)**

你可能敲过很多次类似的命令了，但你有没有想过，为什么这个命令能开启一个远程的交互式 shell，`-i` 和 `-t` 参数又是用来干什么的呢？ 

接下来我们就逐一解释清楚。

# 基础知识

在深入之前，我们先回想一下在自己的 PC 上是怎么运行命令的。

直观地讲，我们会在 `shell`（比如 `Bash`）里执行一些程序，假如这些程序是交互式的，比方说 `mysql-cli`，那在执行后我们还需要输入一些文本指令比如 `DROP DATABASE xxx;`，再从屏幕上看到一些执行结果。

第一个问题来了，我们从键盘输入的指令是怎么传达给进程的，进程的 STDOUT/STDERR 输出又是怎么回显给我们的呢？

## TTY

这就要说到 TTY(即 Terminal)了，TTY 是[Teletype](https://en.wikipedia.org/wiki/Teleprinter)（电传打字机）的缩写，典型的 Teletype 长这样（下图是 ASR33，第一个 Unix 终端）：

![这就是TTY](http://ww1.sinaimg.cn/large/bf52b77fly1g0pq5fwuj0j22001i0u0x.jpg)

虽然是老古董了，但它可是啥也不缺，有输入设备也有输出设备，这就是早期计算机跟人打交道的一种终端（Terminal）。

所以，最早的 "TTY" 是一种纯硬件设备，并且只能处理字符。而随着硬件和操作系统的演进，Teletype 很快就被显示器+键盘取代了。这时候 TTY 这个缩写虽然流传下来了，但不再是专门的硬件，而是由软件进行模拟仿真(Emulate)了。为啥叫仿真呢？因为现在我们的显示器没有能够直接输出字符的硬件设备了，因此我们需要在软件层渲染出一帧文字图像，再交给显示器去展示，随着我们的输入，显示器上也啪嗒啪嗒出现字符，**就像一台 Teletype 一样**（仿真）。

这个软件就叫做 [`Terminal Emulator`](https://en.wikipedia.org/wiki/Terminal_emulator)（终端仿真器）。而我们现在说的 `TTY`，其实就是`Terminal Emulator`了。

软件层面的迭代总是方便很多，很快，大家就发现输入命令时，打错字是难以避免的，要是我们输入的所有内容都直接被发送给了程序，那也就没有后悔药吃了。因此我又在内核里增加了一些逻辑来 buffer 输入的内容，等我们编辑得满意了，再发送过去。这个逻辑在内核的 [`Line discipline`](https://en.wikipedia.org/wiki/Line_discipline) 中。另外，`Line discipline` 这一层还会帮助我们把`CTRL-C`、`CTRL-L`这样的输入转化成控制指令，这样我们的键盘上就不用设计 `终止程序`，`清屏`这样的奇怪按钮了；

## Pseudo TTY

其实，大家平时很少会用到 TTY，比如，我们使用 `shell` 时一般是这个样子的：

![](http://ww1.sinaimg.cn/large/bf52b77fly1g0puwvzdhmj21fi102dqy.jpg)

没错吧？其实我们往往是在图形用户界面里开一个 "Terminal" 程序，这个程序其实就是一个 `Pseudo TTY`，或者叫 [`Pseudoterminal`](https://en.wikipedia.org/wiki/Pseudoterminal)（简称 PTY）。

为什么要在 TTY 之外增加一个 PTY 呢？道理也很简单，`Terminal Emulator` 是内核中的逻辑，用户是动不了的，而作为用户，我们可不想所有的 Terminal 都是黑漆漆的一整屏字符。我们希望实现更多的需求，比如像上图中那样用一个 GUI 中的窗口打开 Terminal，或者说打开一个连接到远端主机的 Terminal。这时，我们需要对 Terminal 的输入输出要完整的掌控能力。为此，内核就提供了 PTY 即伪终端机制来帮助我们实现需求。

PTY 的示意图如下：

可以看到，PTY Slave 其实是直接和我们运行的进程进行输入输出交互的，这些输入输出通过内核中的一些 `Line discipline` 这样的逻辑后，来到 PTY Master，再接到用户空间的 PTY 进程中，这个进程就可以任意掌控如何展示这些内容了。

> 要访问内核的 `Terminal Emulator`(TTY) 也很简单，大多数 Linux 发行版里摁 `ctrl+alt+F2` 即可

## STDIN/STDOUT/STDERR

理解了 TTY 和 PTY 之后，我们就能理解怎样和进程进行交互了：我们知道所有进程在启动时，都会自动创建 0/1/2 这三个文件描述符，即 STDIN/STDOUT/STDERR，而进程的这三个描述符默认就是和 TTY 或 PTY Slave 绑定的。因此我们的输入以及程序的输出就和我们的 Terminal 打通了。

至此，我们总算理清操作自己电脑上的 shell 是怎么实现的了。

# 回到 kubectl exec

刚刚我们提到的 PTY 其实就可以涵盖 kubectl exec 的大部分原理。

# CRI

# 应用

# Reference

* [The TTY demystified](http://www.linusakesson.net/programming/tty/)




