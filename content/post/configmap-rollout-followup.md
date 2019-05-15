---
title: "Kubernetes 中的 ConfigMap 配置更新(续)"
date: 2019-05-15T21:03:16+08:00
lastmod: 2019-05-15T21:03:16+08:00
draft: false
tags: ["kubernetes"]
author: "alei"
toc: true
---

> 之前的文章 [Kubernetes Pod 中的 ConfigMap 更新](https://aleiwu.com/post/configmap-hotreload/) 中，我总结了三种 ConfigMap 或 Secret 的更新方法: [通过 Kubelet 的周期性 Remount 做热更新](https://aleiwu.com/post/configmap-hotreload/#%E7%83%AD%E6%9B%B4%E6%96%B0%E4%BA%8C-%E4%BD%BF%E7%94%A8-sidecar-%E6%9D%A5%E7%9B%91%E5%90%AC%E6%9C%AC%E5%9C%B0%E9%85%8D%E7%BD%AE%E6%96%87%E4%BB%B6%E5%8F%98%E6%9B%B4)，[通过修改对象中的 PodTemplate 触发滚动更新](https://aleiwu.com/post/configmap-hotreload/#pod-%E6%BB%9A%E5%8A%A8%E6%9B%B4%E6%96%B0%E4%B8%80-%E4%BF%AE%E6%94%B9-ci-%E6%B5%81%E7%A8%8B)，以及[通过自定义 Controller 监听 ConfigMap 触发更新](https://aleiwu.com/post/configmap-hotreload/#pod-%E6%BB%9A%E5%8A%A8%E6%9B%B4%E6%96%B0%E4%BA%8C-controller)。但在最近的业务实践中，却碰到了这些办法都不好使的情况。这篇文章就将更为深入地讨论这个主题。

# 问题在哪？

这次碰到的问题，并不是上面的办法**无法实现配置热更新**，而是**无法实现配置滚动发布**。我们不妨看一个常见的例子，一个 `Deployment` 引用了一个 `ConfigMap` (简洁起见，删去了 selector 和 labels 等字段)：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  template:
    annotations:
      nginx-config-md5: d41d8cd98f00b204e9800998ecf8427e
    spec:
      containers:
      - name: nginx
        image: nginx
        volumeMounts:
        - name: nginx-config
          mountPath: /etc/config
      volumes:
      - name: config-volume
        configMap: 
          name: nginx-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
data:
  nginx.conf: |-
    ## some configurations...
```

这里我们采用了 [通过修改对象中的 PodTemplate 触发滚动更新](https://aleiwu.com/post/configmap-hotreload/#pod-%E6%BB%9A%E5%8A%A8%E6%9B%B4%E6%96%B0%E4%B8%80-%E4%BF%AE%E6%94%B9-ci-%E6%B5%81%E7%A8%8B) 这个方案来做 ConfigMap 的更新：

* 每次部署时，计算 ConfigMap 的摘要(e.g. MD5)，并填入 PodTemplate 的 Annotation 中;
* 假如 ConfigMap 发生变化，则摘要也会变化[^1],此会触发一次 Deployment 的滚动更新;

现在，我们更新了一次配置，但很不幸新的配置是**错误**的，使用错误配置的 Pod 将无法正常工作（比如无法通过 `readinessProbe` 的检查）。最终，滚定更新的过程会卡住，错误的配置并不会让你的 Deployment 整个宕掉。

真的是这样吗？

并不是！

问题在这里就显现出来了，`nginx-config` 已经更新成了错误的值，尽管**尚未重建的 Pod**目前暂且健康，但是，一旦这些 Pod 宕掉发生 Pod 重建，或者 Pod 中的容器重新读取了一次配置，这些 Pod 就会进入异常状态：整个集群现在是摇摇欲坠的。

问题的根源是，**在原地更新 ConfigMap 或 Secret 时，我们没有做滚动发布，而是一次性将新配置更新到了整个集群的所有实例中**，我们所谓的"滚动更新"其实是在控制各个实例**何时读取新配置**，但由于 Pod 随时可能挂掉重建，我们是无法做到准确控制这个过程的。

假如你认为“错误的配置“很少见，那一个更有力的例子是 StatefulSet 的灰度发布（使用 StatefulSet 的 Partition 字段控制只把部分副本更新到新的 ControllerRevision)，假如我们 StatefulSet 的配置也做灰度发布，那配置更新的问题就更明显了。

显然，同样的问题对于另两种更新方案也存在。当然，这并不是说这三种方式是错误的，它们也有自己适用的场景，只是当我们需要配置文件的更新滚动发布时，它们就不再适用了。

# 解决方案

上述方案的问题在于原地更新，要解决这个问题，我们只需要在每次 ConfigMap 变化时，重新生成一个 ConfigMap，再更新 Deployment 使用这个新的 ConfigMap 即可。而重新生成 ConfigMap 最简单的方式就是在 ConfigMap 的命名中加上 ConfigMap 的 data 值计算出的摘要，比如:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config-d41d8cd98f00b204e9800998ecf8427e
data:
  nginx.conf: |-
    ## some configurations...
```

事实上，ConfigMap 滚动更新（ConfigMap Rollout）是社区中历时最久而尚未解决的问题之一（[#22368](22368)), 到目前为止，解决这个问题的方向也正是"每次更新新建一个 ConfigMap"这种"Immutable ConfigMap"模式(详见[这条评论](https://github.com/kubernetes/kubernetes/issues/22368#issuecomment-421141188))。

这个方案自然就带来两个问题：

* 如何做到每次配置文件更新时，都创建一个新的 ConfigMap？
  * 目前社区的态度是把这一步放到 Client 来解决，比如 kustomize 和 helm
* 历史 ConfigMap 会不断积累，怎么回收？
  * 针对这点，社区希望在服务端实现一个 GC 机制来清理没有任何资源引用的 ConfigMap
  
当然，把逻辑放到 Client 里势必造成重复造轮子的问题：每一个工具都必须实现一遍类似的逻辑。因此也有人提议通过 Snapshot 的方式把逻辑全都推到服务端，这个方向目前八字都还没一撇，我们且按下不表。至少到现在为止，在 Client 做 ConfigMap 的新建与 Deployment 等对象的更新是最成熟的 ConfigMap 滚动更新方案。

因此，我们就在最后一节来说明 Helm 和 Kustomize 里怎么实现这个方案。

# Helm 和 Kustomize 的实践方式


## Kustomize

kustomize 对这个方案有内置的支持，只需要使用 `configGenerator` 即可：
```yaml
configMapGenerator:
- name: my-configmap
  files:
  - common.properties
```
这段 yaml 在 kustomize 中就会生成一个 ConfigMap 对象，这个对象的 data 来自于 `common.properties` 文件，并且 name 中会加上该文件的 SHA 值作为后缀。

在 kustomize 的其它 layer 中，只要以 `my-configmap` 作为 name 引用这个 ConfigMap 即可，当最终渲染时，kustomize 会自动进行替换操作。

## Helm

首先注意，Helm 在 [tips and tricks](https://github.com/helm/helm/blob/master/docs/charts_tips_and_tricks.md#automatically-roll-deployments-when-configmaps-or-secrets-change) 里提到的修改 Annotation 的方案是无法做到滚动更新的，原因见第一节，假如你想要的是合理的滚动更新的话，注意不要踩到坑里去。

Helm 对于这个方案没有比较好的支持，需要依托于 named template 机制来封装一下。思路是定义一个 named template，用于渲染 ConfigMap 的 data，然后针对这个 named template 计算 SHA 值并添加到 ConfigMap 名字中。

```
{{/*
定义一个 Named Template，将配置文件渲染为 ConfigMap
*/}}
{{- define "my-configmap.data" -}}
config.toml: |-
{{ include (print $.Template.BasePath "/_config.toml.tpl") . | indent 2 }}
another-config.yaml: |-
{{ include (print $.Template.BasePath "/_another-config.yaml.tpl") . | indent 2 }}
{{- end -}}

{{/*
ConfigMap 部分
*/}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-configmap-{{ include "my-configmap.data" . | sha256sum | trunc 8 }}
data:
{{ include "my-configmap.data" . | indent 2 }}
---
{{/*
Deployment 部分
*/}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 3
  template:
    spec:
      volumes:
        - name: my-config
          configMap:
            name: my-configmap-{{ include "my-configmap.data" . | sha256sum | trunc 8 }}
...(其它字段略)
```

其实取巧的地方只有一个，那就是把 configmap 的 data 定义成 Named Template，这样就可以很容易地访问这个模板的渲染值并且计算 SHA。

当然上面只是个示例，正式写 chart 时，还要做好合理的文件切分，比如把 Named Template 放到 `_helpers.tpl`文件中统一维护。

> 当资源名字改变后，Helm 会自动删除旧的资源，因此使用 Helm 时不必担心 ConfigMap 累计过多的问题。缺点就是我们无法脱离 helm 去做 rollback。

# 结语

事实上这种从 Client 端出发的解决方案并不是很优雅，或多或少都有比较 Hack 的感觉。尽管客观情况是 ConfigMap 和 Secret 现在的用法已经完全深入到所有的 Kubernetes 使用场景中，对于如此基础的资源，很难大刀阔斧地去做改进，甚至于小修小补都是"牵一发而动全身"，需要非常慎重地去考虑。但社区的创造力是无穷的，最近又有相关的 [KEP](https://github.com/kubernetes/enhancements/pull/948) 涌现出来(尽管还很粗糙)，相信在不远的将来，我们会看到更好用的 ConfigMap Rollout 管理机制。
