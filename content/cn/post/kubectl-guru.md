---
title: "Kubectl 效率提升指北"
date: 2019-03-31T16:15:33+08:00
lastmod: 2019-03-31T16:15:33+08:00
draft: false
keywords: ["kubernetes","kubectl"]
tags: ["kubernetes"]
categories: ["kubernetes"]
author: "alei"
toc: true
comment: true
autoCollapseToc: false
---

> 写水文啦啦啦啦啦啦啦

kubectl 可能是 Kubernetes(k8s) 最好用的用户接口, 但各种工具都得自己打磨打磨才能用得顺手, kubectl 也不例外. 日常使用起来仍然有比较繁琐的地方, 比如同时查看多个容器的日志, 自定义 `get` 的输出格式. 下面就讲一些 kubectl 的使用经验(具体操作大多以 `zsh` 和 `brew` 为例).

# 准备工作: RTFM (读文档!)

根据[官方速查表](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)配置好 kubectl 的**自动补全**:

* Bash
```shell
echo "source <(kubectl completion bash)" >> ~/.bashrc
```
* Zsh
```shell
echo "if [ $commands[kubectl] ]; then source <(kubectl completion zsh); fi" >> ~/.zshrc
```

假如你对 kubectl 不太熟悉, 速查表里余下的内容能快速让你上手, 建议一读. 另外, github 上还有一份更全面的适合打印的速查表 [cheatsheet-kubernetes-A4](https://github.com/dennyzhang/cheatsheet-kubernetes-A4/blob/master/cheatsheet-kubernetes-A4.pdf) 

# 0.别名

执行下面的命令:

```shell
cat>>~/.zshrc<<EOF
alias k='kubectl'
alias ka='kubectl apply --recursive -f'
alias kex='kubectl exec -i -t'
alias klo='kubectl logs -f'
alias kg='kubectl get'
alias kd='kubectl describe'
EOF
```

我习惯把 `kubectl` alias 成 `k`. 而剩下几个都是很固定的命令与参数组合. 后面还会讲到 kubectl plugin, 所有的命令都要以 kubectl 开头, 因此(~~研究表明~~)用 `k` 能大大保护我们使用 kubectl 时的键盘寿命.

另外 Github 上有一个项目叫做[kubectl-aliases](https://github.com/ahmetb/kubectl-aliases), 能够自动生成一份巨长的 bash 别名列表. 不过我并没有使用, 因为足足有 800 多个别名, 摁 tab 自动补全的时候会卡.

# 1.kubectl plugin 机制

从 1.12 开始, kubectl 就支持从用户的 PATH 中通过**名字**自动发现插件: 所有名字为`kubectl-{pluginName}`格式的可执行文件都会被加载为 kubectgl 插件, 而调用方式就是 kubectl pluginName.

举个例子, 我们有一个可执行文件叫 `kubectl-debug`, 那么就可以用 `kubectl debug` 来执行它, 在设置了别名之后只需要敲 `k debug` 就行了. 我习惯将所有 kubernetes 相关的命令行工具都重命名成 kubectl 插件的形式, 这有两个好处, 一是方便记忆, 二是假如那个工具本身没有自动补全的话, 可以复用 kubectl 的自动补全(比如 `--namespace`). 下面好多地方我们都会利用这个机制来组织命令.

# 2.Context 和 Namespace 切换

一直敲 `--context=xxx -n=xxx` 是很麻烦的事情, 而 kubectl 切换 context 和 namespace 又比较繁琐. 而 [kubectx](https://github.com/ahmetb/kubectx) 就很好的解决了这个问题(结合 [fzf](https://github.com/junegunn/fzf) 体验更棒)

```shell
brew install kubectx
brew install fzf # 辅助做 context 和 namespace 的模糊搜索
```

装完之后基本操作, 重命名成 kubectl 插件的格式:

```shell
mv /usr/local/bin/kubectx /usr/local/bin/kubectl-ctx
mv /usr/local/bin/kubens /usr/local/bin/kubectl-ns
```

示例:

![kubectx](/img/kubectl/kubectx.gif)

# 3.tail 多个 Pod 的日志

`kubectl logs` 有一个限制是不能同时 tail 多个 pod 中容器的日志(可以同时查看多个, 但是此时无法使用 `-f` 选项来 tail). 这个需求很关键, 因为请求是负载均衡到网关和微服务上的, 要追踪特定的访问日志最方便的办法就是 tail 所有的网关再 grep. 比较好的解决方案是 [stern](https://github.com/wercker/stern) 这个项目, 除了可以同时 tail 多个容器的日志之外, stern 还:

* 允许使用正则表达式来选择需要 tail 的 PodName
* 为不同 Pod 的日志展示不同的颜色
* tail 过程中假如有符合规则的新 Pod 被创建, 那么会自动添加到 tail 输出中

可以说是非常方便了. 老样子, 还是加入到我们的 kubectl 插件中:

```shell
brew install stern
mv /usr/local/bin/stern /usr/local/bin/kubectl-tail
# tail 当前 namespace 所有 pod 中所有容器的日志
k tail .
```
示例:

![tail](/img/kubectl/tail.gif)

# 4.使用 jid 和 jq

```shell
brew install jq
brew install jid
```

这个跟 kubectl 放在一起其实不太合适, 因为 [jid](https://github.com/simeji/jid) 和 [jq](https://github.com/stedolan/jq) 适合所有要操作 json 的场景, 但假如你还经常用 `kubectl get pod -o yaml | grep xxx`, 那就可以考虑一下 jid + jq 了. 简单说, jq 是对 json 做过滤和转换的, 比如:

```shell
kubectl get pod -o json | jq '.items[].metadata.labels'
```

这条命令就能提取出所有 pod 对象的 labels, 而 k8s 的对象都很复杂, 我自己是记不住具体的字段位置的, 这时就可以用 jid(**j**son **i**ncremental **d**igger) 来交互式地探索 json 对象的内容:

```shell
# jid 交互式查询的管道输出是最后确定的 JsonPath, 我们直接拷贝到剪切板里给 jq 用
kubectl get pod -o json | jid -q | pbcopy
```

看动图, 基本上用 `tab` 就可以完成探索, 完成之后把对应的 jsonpath 贴到 jq 里即可(注意 `jid` 不支持 Array/Map 通配, 需要手动把 `[0]` 里的下标去掉):

![jq](/img/kubectl/jidjq.gif)

假如需要输出多个字段, 那可以反复用 jid 去把字段都找出来, 最后再 jq 里用逗号分隔字段.

另外, `jq` 本身远比动图里展示得强大(它甚至是一个图灵完备的函数式编程语言), 你可以看看 jq 的 [cookbook](https://github.com/stedolan/jq/wiki/Cookbook) 来体会一下(我只会搞搞基本的 json 转化, 假如真的像 cookbook 里那样去钻研一下的话下面两节估计都不需要了...)

# 5.使用 Custom Columns

jq 的默认输出格式是 json, 看起来不如 `kubectl get` 的表格格式那么清晰, 这时候可以用 `-r` 参数和 `@tsv` 操作符输出成表格格式, 比如下面这个查询所有 `deployment` 使用的 docker image 的指令: 

```bash
$ kg deploy -o json | jq -r '.items[] | [.metadata.name, .spec.template.spec.containers[].image] | @tsv'
aylei-master-discovery	pingcap/tidb-operator:latest
aylei-master-monitor	prom/prometheus:v2.2.1	grafana/grafana:4.6.5
qotm	datawire/qotm:1.3
rss-site	nginx
tiller-deploy	gcr.io/kubernetes-helm/tiller:v2.12.3
```

> tips: API 对象的 shortname 可以用 `kubectl api-resources` 查看

其实效果仍然一般. 还好, 对于大部分 `jq` 能实现的转化, `kubectl get` 命令的 `-o=custom-columns` 参数也能实现, 并且输出结果的对齐与表头更友好(同时可以不依赖 `jq`):

```bash
$ k get deploy -o=custom-columns=NAME:'.metadata.name',IMAGES:'.spec.template.spec.containers[*].image'
NAME                     IMAGES
aylei-master-discovery   pingcap/tidb-operator:latest
aylei-master-monitor     prom/prometheus:v2.2.1,grafana/grafana:4.6.5
qotm                     datawire/qotm:1.3
```

> 虽然语法略有不同, 但 custom-columns 里的 jsonpath 仍然可以通过 jid 去探索式地获取

(注意 `custom-columns` 中使用的 [JSONPath 语法](https://kubernetes.io/docs/reference/kubectl/jsonpath/) 和 `jq` 是不同的, 通配 list 需要用 `[*]`)

# 6.定制自己的输出格式

`jq` 和 `custom-columns` 都有一个问题是命令太长了, 即使我们用 alias 这么一行巨长的命令也不好维护. 还好, `jq` 和 `custom-columns` 都支持从文件中选择查询, 考虑到 `custom-columns` 的输出效果比较好, 更适合作为默认输出(jq 我一般用来做 adhoc query), 因此我们可以在 `custom-columns` 的基础上再封装一下.

`kubectl get` 的 `-o=custom-columns-file=<file>` 这个参数可以选定一个文件来提供 `custom-columns` 的信息, 文件格式非常简单:

```
NAME           IMAGE
.metadata.name .spec.template.spec.containers[*].image
```

但要指定文件感觉还是很麻烦, 怎么办呢? 刚刚讲的 kubectl 插件机制就派上用场了, 我们可以实现一个插件来展示自定义的输出格式, 而编写方式嘛, Bash 就足够啦, 执行下面的命令直接写完:

```bash
cat>>kubectl-ls<<EOF
#!/bin/bash

# see if we have custom-columns-file defined
if [ ! -z "$1" ] && [ -f $HOME/.kube/columns/$1 ];
then
    kubectl get -o=custom-columns-file=$HOME/.kube/columns/$1 $@
else
    kubectl get $@
EOF
```

这个脚本的意思是假如某种资源存在对应的 `~/.kube/columns/{resourceKind}` 这个文件, 就使用这个文件作为 columns 的模板. 为了和 get 命令区分开来(插件不能和内置指令同名), 就用了 `ls` 这个名字. 接下来, 我们将刚刚创建的 `kubectl-ls` 文件安装到 PATH 中, 再创建一个针对 `deploy` 资源的模板文件:

```shell
chmod a+x kubectl-ls
mv kubectl-ls /usr/local/bin/kubectl-ls
mkdir -p ~/.kube/columns
cat>>~/.kube/columns/deploy<<EOF
NAME           IMAGE
.metadata.name .spec.template.spec.containers[*].image
EOF
```

大功告成, 接下来, 我们的 `kubectl ls` 就能根据文件配置自动转换 kubectl 输出:

```shell
$ k ls deploy
NAME                     IMAGE
aylei-master-discovery   pingcap/tidb-operator:latest
aylei-master-monitor     prom/prometheus:v2.2.1,grafana/grafana:4.6.5
qotm                     datawire/qotm:1.3
rss-site                 nginx
tiller-deploy            gcr.io/kubernetes-helm/tiller:v2.12.3
tmp-shell                netdata/netdata
```

这个脚本对 CRD(Custom Definition Resources) 尤其有用, 很多 CRD 没有配置 `additionalPrintColumns` 属性, 导致 `kubectl get` 输出的内容就只有一个名字, 比如 Prometheus Operator 定义的 Prometheus 对象, 根本没有信息嘛:

```shell
$ kg prometheus
NAME   CREATED AT
k8s    7d
```

其实定制一下我们就能看到更合理的输出:
```shell
cat>>~/.kube/columns/prometheus<<EOF
NAME          REPLICAS      VERSION      CPU                         MEMORY                         ALERTMANAGER
metadata.name spec.replicas spec.version spec.resources.requests.cpu spec.resources.requests.memory spec.alerting.alertmanagers[*].name
EOF
```

噔噔噔噔:
```shell
$ k ls prometheus k8s
NAME   REPLICAS   VERSION   CPU      MEMORY   ALERTMANAGER
k8s    2          v2.5.0    <none>   400Mi    alertmanager-main
```

# 结语

OK(终于水完了...), 这些配置其实都带有很强的个人色彩, 我自己用着非常顺手, 但可能到大家那边就未必如此了. 因此这篇文章只能勉强算是抛砖引玉, 假如能有一两点帮助大家提升了效率, 那也就达到目的了.

