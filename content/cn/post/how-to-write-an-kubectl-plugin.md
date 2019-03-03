---
title: "如何写一个 kubectl 插件"
date: 2019-03-03T10:42:50+08:00
lastmod: 2019-03-03T10:42:50+08:00
draft: true
keywords: ["kubernetes","kubectl","plugin","how-to"]
tags: ["kubernetes"]
categories: ["kubernetes"]
author: "alei"
toc: true
comment: true
autoCollapseToc: falsee
---

使用 Kubernetes（以下称 k8s）的时候，我们经常会开发一些定制化的用户接口，比如 `istio` 项目的 `istioctl`，各种公司内部 PaaS 平台的 Web-UI。无论形式是 CLI 还是 GUI，这些扩展的目的都是为了用户更方便、更安全地操作 k8s 中的各种资源。

对我个人而言，我偏向于将这些用户接口以 `kubectl plugin` 的形式进行交付。`kubectl plugin` 是 `kubectl` 本身的一种插件机制，它允许我们为 `kubectl` 添加自定义的新命令，添加后的使用形式如下所示：

```shell
$ kubectl <custom-command> <flags>
```

举个例子，我们可以实现一个新命令 `kubectl tail`，用于同时 tail 多个 Pod 中容器的日志。

# 插件机制概述 