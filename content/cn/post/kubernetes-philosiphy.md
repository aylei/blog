---
title: "在 Kubernetes 上构建应用：Kubernetes 扩展概览"
date: 2019-04-03T14:45:56+08:00
lastmod: 2019-04-03T14:45:56+08:00
draft: true
keywords: []
tags: []
categories: []
author: "alei"
toc: true
comment: true
autoCollapseToc: false
---

> 这篇文章从我在公司内部的分享"Kubernetes Extensions Practice"总结而来。原分享侧重于分析 Kubernetes 的扩展点，这篇博客里我加上了一句"在 Kubernetes 上构建应用"，试图从我自己的角度总结一下 Kubernetes 上的应用到底怎么玩。

Kubernetes(k8s) 的风已经吹了好多年，整个生态也是越来越成熟，类似"Kubernetes 是下一代操作系统"这样的论调愈发风靡。其实从某种程度上来说，Kubernetes 的风靡是一个必然。大家可能听说过 Mesos 很多年就喊出的一个概念叫"DCOS"，也就是做整个数据中心的操作系统。没错，随着整体的架构复杂度提升，基础资源规模变大，整个行业势必需要一个像单机操作系统封装底层硬件那样封装分布式硬件资源的"集群操作系统"，而 Kubernetes 则依靠自身的实力与运势成为了这个"集群操作系统"的事实标准。

# Kubernetes 架构回顾

# 扩展的两种模式

# 扩展点与实际应用