---
title: "Jsonnet 简明教程与应用"
date: 2019-04-07T13:48:47+08:00
lastmod: 2019-04-07T13:48:47+08:00
draft: false
keywords: ["jsonnet", "grafana", "kubernetes"]
tags: ["kubernetes"]
categories: ["kubernetes"]
author: "alei"
toc: true
comment: true
autoCollapseToc: false
---

> Jsonnet 的功能用主流语言也能很快实现, 因此我一直都不关注这门语言. 直到最近做 Grafana 声明式看板的时候才重新审视了一遍这门语言, 认识到 Jsonnet 其实在"灵活"和"限制"上有一个很好的平衡. 同时, k8s 和 grafana 社区也有很多 jsonnet 的库, 这两点给学习 jsonnet 提供了足够的理由.

# Jsonnet

[Jsonnet](https://jsonnet.org/) 是 Google 推出的一门 JSON 模板语言. 它的基本思想是在 JSON 的基础上扩展语法, 将 JSON 的部分字段用代码来表达, 并在运行期生成这些字段. Jsonnet 本身非常简单, 花五分钟跟着下面的代码在命令行走一遍就能掌握基本用法:

PS: 我不会列出所有的语法和细节, 只会写必要的部分, 掌握了这些部分, 我们就可以看懂所有的 jsonnet 库并且动手修改它们 (详细的文档请见: [Jsonnet Tutorial](https://jsonnet.org/learning/tutorial.html)
PSS: `cat>test.jsonnet<<EOF` 的作用是使用两个 EOF 之间的文本覆写 `test.jsonnet` 文件, 因此假如你使用 IDE 的话, 复制两个 EOF 之间的内容即可

```shell
# 安装 Jsonnet(C 实现)
$ brew install jsonnet

# 也可以安装 Go 实现
$ go get github.com/google/go-jsonnet/cmd/jsonnet

# 基本用法: 解释运行一个 jsonnet 源码文件
$ echo "{key: 1+2}" > test.jsonnet
$ jsonnet test.jsonnet
{
   "key": 3
}

# 对于简单的代码也可以使用 -e 直接运行
$ jsonnet -e '{key: 1+2}'
{
   "key": 3
}

# format 源码文件
$ jsonnet fmt test.jsonnet

# Jsonnet 语法比 JSON 更宽松(类似 JS):
# 字段可以不加引号; 支持注释; 字典或列表的最后一项可以带逗号
$ cat>test.jsonnet<<EOF
/* 多行
注释 */
{key: 1+2, 'key with space': 'key with special char should be quoted'}
// 单行注释
EOF
$ jsonnet test.jsonnet
{
   "key": 3,
   "key with space": "key with special char should be quoted"
}

# 类比: Jsonnet 支持与主流语言类似的四则运算, 条件语句, 字符串拼接, 字符串格式化, 数组拼接, 数组切片以及 python 风格的列表生成式
$ cat>test.jsonnet<<EOF
{
  array: [1, 2] + [3],
  math: (4 + 5) / 3 * 2,
  format: 'Hello, I am %s' % 'alei',
  concat: 'Hello, ' + 'I am alei',
  slice: [1,2,3,4][1:3],
  'list comprehension': [x * x for x in [1,2,3,4]],
  condition:
    if 2 > 1 then 
    'true'
    else 
    'false',
}
EOF
$ jsonnet test.jsonnet
{
   "array": [
      1,
      2,
      3
   ],
   "concat": "Hello, I am alei",
   "condition": "true",
   "format": "Hello, I am alei",
   "list comprehension": [
      1,
      4,
      9,
      16
   ],
   "math": 6,
   "slice": [
      2,
      3
   ]
}

# 使用变量:
#   使用 :: 定义的字段是隐藏的(不会被输出到最后的 JSON 结果中), 这些字段可以作为内部变量使用(非常常用)
#   使用 local 关键字也可以定义变量
#   JSON 的值中可以引用字段或变量, 引用方式:
#     变量名
#     self 关键字: 指向当前对象
#     $ 关键字: 指向根对象
$ cat>test.jsonnet<<EOF
{
  local name = 'aylei',
  language:: 'jsonnet',
  message: {
    target: $.language,
    author: name,
    by: self.author,
  }
}
EOF
$ jsonnet test.jsonnet
{
   "message": {
      "author": "aylei",
      "by": "aylei",
      "target": "jsonnet"
   }
}

# 使用函数:
# 函数(或者说方法)在 Jsonnet 中是一等公民, 定义与引用方式与变量相同, 函数语法类似 python
$ cat>test.jsonnet<<EOF
{
  local hello(name) = 'hello %s' % name,
  sum(x, y):: x + y,
  // newObj 这种用法在各种 jsonnet 的 lib 库中非常常见, 是一种很好的代码复用方式
  newObj(name='alei', age=23, gender='male'):: {
    name: name,
    age: age,
    gender: gender,
  },
  call_sum: $.sum(1, 2),
  call_hello: hello('world'),
  me: $.newObj(age=24),
}
EOF
$ jsonnet test.jsonnet
{
   "call_hello": "hello world",
   "call_sum": 3,
   "me": {
      "age": 24,
      "gender": "male",
      "name": "alei"
   }
}

# Jsonnet 使用组合来实现面向对象的特性(类似 Go)
#   Json Object 就是 Jsonnet 中的对象
#   使用 + 运算符来组合两个对象, 假如有字段冲突, 使用右侧对象(子对象)中的字段
#   子对象中使用 super 关键字可以引用父对象, 用这个办法可以访问父对象中被覆盖掉的字段
#   假如希望组合两个对象中的嵌套对象, 比如 a.b 和 c.b, 那么可以使用 +: 运算符:
#      子对象中使用 +: 定义的字段在组合时会与父对象中的相同字段进行组合, 而非覆盖
#   注意 jsonnet 的延迟计算特性: 所有信息都是在解释执行时才进行计算的
$ cat>test.jsonnet<<EOF
local base = {
  f: 2,
  g: self.f + 100,
};
base + {
  f: 5,
  old_f: super.f,
  old_g: super.g,
}
EOF 
$ jsonnet test.jsonnet
{
   "f": 5,
   "g": 105,
   "old_f": 2,
   "old_g": 105
}

# 有时候我们希望一个对象中的字段在进行组合时不要覆盖父对象中的字段, 而是与相同的字段继续进行组合
# 这时可以用 +: 来声明这个字段 (+:: 与 +: 的含义相同, 但与 :: 一样的道理, +:: 定义的字段是隐藏的)
# 对于 JSON Object, 我们更希望进行组合而非覆盖, 因此在定义 Object 字段时, 很多库都会选择使用 +: 和 +::, 但我们也要注意不能滥用
$ cat>test.jsonnet<<EOF
local child = {
  override: {
    x: 1,
  },
  composite+: {
    x: 1,
  },
};
{
  override: { y: 5, z: 10 },
  composite: { y: 5, z: 10 },
} + child
EOF
$ jsonnet test.jsonnet
{
   "composite": {
      "x": 1,
      "y": 5,
      "z": 10
   },
   "override": {
      "x": 1
   }
}

# 库与 import:
#    jsonnet 共享库复用方式其实就是将库里的代码整合到当前文件中来, 引用方式也很暴力, 使用 -J 参数指定 lib 文件夹, 再在代码里 import 即可
#    注意 jsonnet 约定库文件的后缀名为 .libsonnet
$ mkdir some-path
$ cat>some-path/mylib.libsonnet<<EOF
{
  newVPS(ip, region='cn-hangzhou', distribution='CentOS 7', cpu=4, memory='16GB'):: {
    ip: ip,
    distribution: distribution,
    cpu: cpu,
    memory: memory,
    vendor: 'Alei Cloud',
    os: 'linux',
    packages: [],
    install(package):: self + {
      packages+: [package],
    },
  }
}
EOF
$ cat>test.jsonnet<<EOF
local vpsTemplate = import 'some-path/mylib.libsonnet';
vpsTemplate
  .newVPS(ip='10.10.44.144', cpu=8, memory='32GB')
  .install('docker')
  .install('jsonnet')
EOF
$ jsonnet -J . test.jsonnet
{
   "cpu": 8,
   "distribution": "CentOS 7",
   "ip": "10.10.44.144",
   "memory": "32GB",
   "os": "linux",
   "packages": [
      "docker",
      "jsonnet"
   ],
   "vendor": "Alei Cloud"
}

# 上面这种 Builder 模式在 jsonnet 中非常常见, 也就是先定义一个构造器, 构造出基础对象然后用各种方法进行修改. 当对象非常复杂时, 这种模式比直接覆盖父对象字段更易维护
# 了解上面这些基本用法之后我们就能看懂几乎所有 jsonnet 的库并且能够自己动手修改了
```

# Jsonnet 使用场景

虽然 Jsonnet 本身是图灵完备的, 但它本身是专门为了生成 JSON 设计的模板语言, 因此使用场景主要集中在配置管理上. 社区的实践主要是用 jsonnet 做 Kubernetes, Prometheus, Grafana 的配置管理, 相关的库有:

* [kubecfg](https://github.com/bitnami/kubecfg): 使用 jsonnet 生成 kubernetes API 对象 并 apply
* [ksonnet-lib](https://github.com/ksonnet/ksonnet-lib): 一个 jsonnet 的库, 用于生成 kubernetes API 对象(在 hepstio 被 IBM 收购之后 IBM 放弃了 ksonnet 这个项目)
* [kube-prometheus](https://github.com/coreos/prometheus-operator/tree/master/contrib/kube-prometheus): 使用 jsonnet 生成 Prometheus-Operator, Prometheus, Grafana 以及一系列监控组件的配置
* [grafonnet-lib](https://github.com/grafana/grafonnet-lib/tree/master/grafonnet): 一个 jsonnet 的库, 用于生成 json 格式的 Grafana 看板配置 

还有一些公司的应用例子:

* [grafana 的 jsonnet-lib](https://github.com/grafana/jsonnet-libs): Grafana 内部使用的 jsonnet-libs, 包含各种配置的管理
* [databrikcs 的 jsonnet-style-guide](https://github.com/databricks/jsonnet-style-guide): Databricks 的 jsonnet 风格指南, 里面还讲了 databricks 是怎么使用 jsonnet 的

k8s 资源对象生成相关的场景对我吸引力不大, 因为 kustomize, helm 甚至 kubernetes operator 从某种程度上来说都是做这件事的, jsonnet 相比之下并没有特别的优势. 但在监控这一块, 由于 Prometheus 相关社区(Grafana, Prometheus-Operator, kube-prometheus) 都使用 jsonnet 做配置管理, 我们也不得不入乡随俗了.

> prometheus 也有 helm 的 chart, 但完善程度以及可定制性被基于 jsonnet 的 kube-prometheus 完爆

我们就以 [grafonnet-lib](https://github.com/grafana/grafonnet-lib/tree/master/grafonnet) 为例, 探究如何使用 jsonnet 库来便捷地生成复杂 JSON 并根据自己的需求改进 jsonnet 库.

# Grafonnet

首先 clone grafonnet 到本地:

```shell
$ git clone https://github.com/grafana/grafonnet-lib.git
$ cd grafonnet-lib
# 简单看一眼这个库提供的 .libsonnet, 可以看到, 库的入口文件聚合了各个模块, 这也是一种 jsonnet 的常见模式
$ cat grafonnet/grafana.libsonnet
{
  dashboard:: import 'dashboard.libsonnet',
  template:: import 'template.libsonnet',
  text:: import 'text.libsonnet',
  timepicker:: import 'timepicker.libsonnet',
  row:: import 'row.libsonnet',
  link:: import 'link.libsonnet',
  annotation:: import 'annotation.libsonnet',
  graphPanel:: import 'graph_panel.libsonnet',
  tablePanel:: import 'table_panel.libsonnet',
  singlestat:: import 'singlestat.libsonnet',
  influxdb:: import 'influxdb.libsonnet',
  prometheus:: import 'prometheus.libsonnet',
  sql:: import 'sql.libsonnet',
  graphite:: import 'graphite.libsonnet',
  alertCondition:: import 'alert_condition.libsonnet',
  cloudwatch:: import 'cloudwatch.libsonnet',
  elasticsearch:: import 'elasticsearch.libsonnet',
}
```

通过查看各个模块的 jsonnet 代码, 我们就能探索出这个库的所有接口, 可以磕磕绊绊地使用它来生成 Grafana 看板的 JSON 配置了:

```jsonnet
local grafana = import 'grafonnet/grafana.libsonnet';
local dashboard = grafana.dashboard;
local template = grafana.template;
local singlestat = grafana.singlestat;
local prometheus = grafana.prometheus;

dashboard.new(
  'Test',
  schemaVersion=16,
)
.addTemplate(
  grafana.template.datasource(
    'PROMETHEUS_DS',
    'prometheus',
    'Prometheus',
    hide='label',
  )
)
.addPanel(
  singlestat.new(
    'prometheus-up',
    format='s',
    datasource='Prometheus',
    span=2,
    valueName='current',
  )
  .addTarget(
    prometheus.target(
      'up{job="prometheus"}',
    )
  ), 
  gridPos= { x: 0, y: 0, w: 24, h: 3, }
)
```

将上面的内容保存为 `dashboard.jsonnet` 并执行 `jsonnet -J . dashboard.jsonnet`, 你就能看到生成的一大串 JSON.

可以看到, grafonnet 采用的正是我们上面讲到的 Builder 模式.

由于 grafonnet 是一个通用库, 因此我们的 jsonnet 还是比较复杂, 仅仅添加一个图表就写了这么多行, 很显然, 我们可以再封装一层, 去掉很多在自己内部没必要定制的东西, 提供一个更简单的接口. 这时候 jsonnet 的灵活性就展现得很明显了.


# 结语

其实看完 Jsonnet 的功能之后, 我们会发现 jsonnet 的功能用其它语言也能实现, 甚至用 javascript 来实现的话写的代码和 jsonnet 都是有点类似的, 那为什么还要选 Jsonnet 呢? 其实对我而言, 仅仅是因为相关的工作中 Jsonnet 有现成的库可以用, 而且有丰富的文档. 

但从另一个角度来想, Jsonnet 确实有它独特的优越性, 那就是**限制非常大**. 在 Jsonnet 中, 我们无法去访问一个外部的数据库或者 Web 服务来生成配置, 也没法搞各种语言中有趣的奇技淫巧. 这种限制带来的好处是, Jsonnet 每次生成都只依赖于代码文件以及被依赖的代码文件, 那假如用一个放 jsonnet 的 git 仓库来做配置管理, 这个库就是百分之百的 Single Source of Truth, 没有惊喜, 没有意外. 这是把领域性的 Best Practice 从规范和 Code Review 下沉到工具乃至语言本身当中的一个绝佳例子.

