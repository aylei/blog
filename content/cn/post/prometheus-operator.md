---
title: "搞搞 Prometheus：Prometheus Operator"
date: 2019-03-24T14:37:32+08:00
lastmod: 2019-03-24T14:37:32+08:00
draft: false
keywords: ["kubernetes","prometheus","operator"]
tags: ["kubernetes","prometheus"]
categories: ["kubernetes"]
author: "alei"
toc: true
comment: true
autoCollapseToc: false
---

# 前言

我对 [Prometheus](https://github.com/prometheus/prometheus) 是又爱又恨。

* 一方面吧，它生态特别好：作为 Kubernetes 监控的事实标准，（几乎）所有 k8s 相关组件都暴露了 Prometheus 的指标接口，甚至在 k8s 生态之外，绝大部分传统中间件（比如 MySQL、Kafka、Redis、ES）也有社区提供的 Prometheus Exporter。我们已经可以去掉 k8s 这个定语，直接说 Prometheus 是开源监控方案的"头号种子选手"了；
* 另一方面吧，都 2019 年了，一个基础设施领域的"头号种子"选手居然还不支持分布式、不支持数据导入/导出、甚至不支持通过 api 修改监控目标和报警规则，这是不是也挺匪夷所思的？

不过 Prometheus 的维护者们也有充足的理由：Prometheus does one thing, and it does it well[1](https://www.oreilly.com/library/view/prometheus-up/9781492034131/ch01.html). 那其实也无可厚非，Prometheus 最核心的"指标监控"确实做得出色，只是当我们要考虑 scale、考虑 long-term storage、考虑平台化(sth. as a Service)的时候，自己就得做一些扩展与整合了。"搞搞 Prometheus"这个主题可能会针对这些方面做一些讨论，抛砖引玉（不过要是弃坑的话这就是第一篇也是最后一篇了ε=ε=ε=ε=┌(;￣▽￣)┘）。

# Prometheus Operator

这篇文章的主角是 [Prometheus Operator](https://github.com/coreos/prometheus-operator)，由于 Prometheus 本身没有提供管理配置的 API 接口（尤其是管理监控目标和管理警报规则），也没有提供好用的多实例管理手段，因此这一块往往要自己写一些代码或脚本。但假如你还没有写这些代码，那就可以先看一下 Prometheus Operator，它很好地解决了 Prometheus 不好管理的问题。

> 什么是 Operator？Operator = Controller + CRD。假如你不了解什么是 Controller 和 CRD，可以看一个 Kubernetes 本身的例子：我们提交一个 **Deployment 对象**来声明**期望状态**，比如 3 个副本；而 Kubernetes 的 Controller 会不断地干活（跑控制循环）来达成**期望状态**，比如看到只有 2 个副本就创建一个，看到有 4 个副本了就删除一个。在这里，Deployment 是 Kubernetes 本身的 API 对象。那假如我们想自己设计一些 API 对象来完成需求呢？Kubernetes 本身提供了 CRD([Custom Resource Definition](https://kubernetes.io/docs/tasks/access-kubernetes-api/custom-resources/custom-resource-definitions/))，允许我们定义新的 API 对象。但在定义完之后，Kubernetes 本身当然不可能知道这些 API 对象的**期望状态**该如何到达。这时，我们就要写对应的 **Controller** 去实现这个逻辑。而这种自定义 API 对象 + 自己写 Controller 去解决问题的模式，就是 **Operator** Pattern。

# 概览

假如你有一个测试用的 k8s 集群，可以直接按照[这里](https://github.com/coreos/prometheus-operator/tree/master/contrib/kube-prometheus#quickstart)把 Prometheus Operator 以及基于 Operator 的一大坨对象全都部署上去，部署完之后就可以用 `kubectl get prometheus`, `kubectl get servicemonitor` 来摸索新增的 API 对象了(不部署也没关系，咱们纸上谈兵）。新的对象有四种：

* Alertmanager: 定义一个 Alertmanager 集群;
* ServiceMonitor: 定义一组 Pod 的指标应该如何采集;
* PrometheusRule: 定义一组 Prometheus 规则;
* Prometheus: 定义一个 Prometheus "集群"，同时定义这个集群要使用哪些 `ServiceMonitor` 和 `PrometheusRule`;

看几个简化版的 yaml 定义就很清楚了：

```yaml
kind: Alertmanager ➊
metadata:
  name: main
spec:
  baseImage: quay.io/prometheus/alertmanager
  replicas: 3 ➋
  version: v0.16.0
```
* ➊ 一个 Alertmanager 对象
* ➋ 定义该 Alertmanager 集群的节点数为 3

```yaml
kind: Prometheus
metadata: # 略
spec:
  alerting:
    alertmanagers:
    - name: alertmanager-main ➊
      namespace: monitoring
      port: web
  baseImage: quay.io/prometheus/prometheus
  replicas: 2 ➋
  ruleSelector: ➌
    matchLabels:
      prometheus: k8s
      role: alert-rules
  serviceMonitorNamespaceSelector: {} ➍
  serviceMonitorSelector: ➎
    matchLabels:
      k8s-app: node-exporter
  query: 
    maxConcurrency: 100 ➏
  version: v2.5.0
```

* ➊ 定义该 Prometheus 对接的 Alertmanager 集群名字为 main, 在 monitoring 这个 namespace 中;
* ➋ 定义该 Proemtheus "集群"有两个副本，说是集群，其实 Prometheus 自身不带集群功能，这里只是起两个完全一样的 Prometheus 来避免单点故障;
* ➌ 定义这个 Prometheus 需要使用带有 `prometheus=k8s` 且 `role=alert-rules` 标签的 PrometheusRule;
* ➍ 定义这些 Prometheus 在哪些 namespace 里寻找 ServiceMonitor，不声明则默认选择 Prometheus 对象本身所处的 Namespace;
* ➎ 定义这个 Prometheus 需要使用带有 `k8s-app=node-exporter` 标签的 ServiceMonitor，不声明则会全部选中;
* ➏ 定义 Prometheus 的最大并发查询数为 100，[几乎所有配置](https://github.com/coreos/prometheus-operator/blob/master/Documentation/api.md#prometheusspec)都可以通过 Prometheus 对象进行声明(包括很重要的 RemoteRead、RemoteWrite)，这里为了简洁就不全部列出了;

```yaml
kind: ServiceMonitor
metadata:
  labels:
    k8s-app: node-exporter ➊
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels: ➋
      app: node-exporter 
      k8s-app: node-exporter
  endpoints:
  - bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
    interval: 30s ➌
    targetPort: 9100 ➍
    scheme: https
  jobLabel: k8s-app
```

* ➊ 这个 ServiceMonitor 对象带有 `k8s-app=node-exporter` 标签，因此会被上面的 Prometheus 选中;
* ➋ 定义需要监控的 [Endpoints](https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.12/#endpoints-v1-core)，带有 `app=node-exporter` 且 `k8s-app=node-exporter`标签的 Endpoints 会被选中;
* ➌ 定义这些 Endpoints 需要每 30 秒抓取一次;
* ➍ 定义这些 Endpoints 的指标端口为 9100;

> Endpoints 对象是 Kubernetes 对一组地址以及它们的可访问端口的抽象，通常和 Service 一起出现。

```yaml
kind: PrometheusRule
metadata:
  labels: ➊
    prometheus: k8s
    role: alert-rules
  name: prometheus-k8s-rules
spec:
  groups:
  - name: k8s.rules
    rules: ➋
    - alert: KubeletDown
      annotations:
        message: Kubelet has disappeared from Prometheus target discovery.
      expr: |
        absent(up{job="kubelet"} == 1)
      for: 15m
      labels:
        severity: critical
```
* ➊ 定义该 PrometheusRule 的 label, 显然它会被上面定义的 Prometheus 选中;
* ➋ 定义了一组规则，其中只有一条报警规则，用来报警 kubelet 是不是挂了;

串在一起，它们的关系如下:

![](https://raw.githubusercontent.com/coreos/prometheus-operator/master/Documentation/custom-metrics-elements.png)

看完这四个真实的 yaml，你可能会觉得，这不就是把 Prometheus 的配置打散了，放到了 API 对象里吗？**和我自己写 StatefulSet + ConfigMap 有什么区别呢？**

确实，Prometheus 对象和 Alertmanager 对象就是对 StatefulSet 的封装：实际上在 Operator 的逻辑中，中还是生成了一个 StatefuleSet 交给 k8s 自身的 Controller 去处理了。对于 PrometheusRule 和 ServiceMonitor 对象，Operator 也只是把它们转化成了 Prometheus 的配置文件，并挂载到 Prometheus 实例当中而已。

那么，Operator 的价值究竟在哪呢？

# Prometheus Operator 的好处都有啥？

首先，这些 API 对象全都是用 CRD 定义好 Schema 的，**api-server 会帮我们做校验**。

假如我们用 ConfigMap 来存配置，那就没有任何的校验。万一写错了（比如 yaml 缩进错误）：

* 那么 Prometheus 做配置热更新的时候就会失败，假如配置更新失败没有报警，那么 Game Over;
* 热更新失败有报警，但这时 Prometheus 突然重启了，于是配置错误重启失败，Game Over;

而在 Prometheus Operator 中，所有在 Prometheus 对象、ServiceMonitor 对象、PrometheusRule 对象中的配置都是有 Schema 校验的，校验失败 apply 直接出错，这就大大降低了配置异常的风险。

其次，Prometheus Operator 借助 k8s 把 Prometheus 服务平台化了，**实现 Prometheus as a Service**。

在有了 Prometheus 和 Alertmanager 这样非常明确的 API 对象之后，用户就能够以 k8s 平台为底座，自助式地创建 Prometheus 服务或 Alertmanager 服务。这一点我们不妨退一步想，假如没有 Prometheus Operator，我们要怎么实现这个平台化呢？那无非就是给用户一个表单， 限定能填的字段，比如存储盘大小、CPU内存、Prometheus 版本，然后通过一段逻辑填充成一个 StatefuleSet 的 API 对象再创建到 k8s 上。没错，这些逻辑 Prometheus Operator 都帮我们做掉了，而且是用非常 Kubernetes 友好的方式做掉了，我们何必再造轮子呢？

最后，也是最重要的，`ServiceMonitor` 和 `PrometheusRule` 这两个对象**解决了 Prometheus 配置难维护这个痛点问题**。

要证明这点，我得先亮一段 Prometheus 配置：

```yaml
      - job_name: 'kubernetes-service-endpoints'
        kubernetes_sd_configs:
          - role: endpoints
        relabel_configs:
          - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
            action: keep
            regex: true
          - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scheme]
            action: replace
            target_label: __scheme__
            regex: (https?)
          - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
            action: replace
            target_label: __metrics_path__
            regex: (.+)
          - source_labels: [__address__, __meta_kubernetes_service_annotation_prometheus_io_port]
            action: replace
            target_label: __address__
            regex: ([^:]+)(?::\d+)?;(\d+)
            replacement: $1:$2
          - action: labelmap
            regex: __meta_kubernetes_service_label_(.+)
          - source_labels: [__meta_kubernetes_namespace]
            action: replace
            target_label: kubernetes_namespace
          - source_labels: [__meta_kubernetes_service_name]
            action: replace
            target_label: kubernetes_name
          - source_labels: [__meta_kubernetes_pod_node_name]
            action: replace
            target_label: kubernetes_node
```

通过 Prometheus 的 [relabel_config](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config) 文档可以知道，上面这段"天书"指定了:

* 这个 Prometheus 要针对所有 annotation 中带有 `prometheus.io/scrape=true` 的 Endpoints 对象，按照 annotation 中的 `prometheus.io/port`,`prometheus.io/scheme`,`prometheus.io/path`来抓取它们的指标。

Prometheus 平台化之后，势必会有不同业务线、不同领域的各种 Prometheus 监控实例，大家都只想抓自己感兴趣的指标，于是就需要改动这个配置来做文章，但这个配置在实际维护中有不少问题：

* 复杂：复杂是万恶之源；
* 没有分离关注点：应用开发者（提供 Pod 的人）必须知道 Prometheus 维护者的配置是怎么编写的，才能正确提供 annotation；
* 没有 API：更新流程复杂，需要通过 CI 或 k8s ConfigMap 等手段把配置文件更新到 Pod 内再触发 webhook 热更新；

而 `ServiceMonitor` 对象就很巧妙，它解耦了"监控的需求"和"需求的实现方"。我们通过前面的分析可以知道，`ServiceMonitor` 里只需要用 label-selector 这种简单又通用的方式声明一个 **"监控需求"，也就是哪些 Endpoints 需要收集，怎么收集就行了**。而这个需求本身则会被 Prometheus 按照 label 来选中并且满足。让用户只关心需求，这就是一个非常好的关注点分离。当然了，`ServiceMonitor` 最后还是会被 Operator 转化成上面那样复杂的 Scrape Config，但这个复杂度已经完全被 Operator 屏蔽掉了。

另外，`ServiceMonitor` 还是一个字段明确的 API 对象，用 `kubectl` 就可以查看或更新它，在上面包一个 web-ui，让用户通过 ui 选择监控对象也是非常简单的事情。这么一来，很多"内部监控系统"的造轮子工程又可以简化不少。

`PrometheusRule` 对象也是同样的道理。再多想一点，基于 `PrometheusRule` 对象的 Rest API，我们可以很容易地开发一个 Grafana 插件来帮助应用开发者在 UI 上定义警报规则。这对于 devops 流程是非常重要的，我们可不想在一个团队中永远只能去找 SRE 添加警报规则。

还有一点，这些新的 API 对象天生就能够复用 kubectl, RBAC, Validation, Admission Control, ListAndWatch API 这些 Kubernetes 开发生态里的东西，相比于脱离 Kubernetes 写一套 "Prometheus 管理平台"，这正是基于 Operator 模式基于 Kubernetes 进行扩展的优势所在。

# 结语

其实大家可以看到，Prometheus Operator 干的事情其实就是平常我们用 CI 脚本、定时任务或者手工去干的事情，逻辑上很直接。它的成功在于借助 Operator 模式（拆开说就是控制循环+声明式API这两个 k8s 的典型设计模式）封装了大量的 Prometheus 运维经验，提供了友好的 Prometheus 管理接口，而这对于平台化是很重要的。另外，这个例子也可以说明，即使对 Prometheus 这样运维不算很复杂的系统，Operator 也能起到很好的效果。
