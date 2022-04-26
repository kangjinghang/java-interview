# 34. 初搜索引擎_search结果深入解析（search timeout机制揭秘

1、我们如果发出一个搜索请求的话，会拿到一堆搜索结果，本节课，我们来讲解一下，这个搜索结果里的各种数据，都代表了什么含义
2、我们来讲解一下，搜索的timeout机制，底层的原理，画图讲解

GET /_search

```json
{
  "took": 6,
  "timed_out": false,
  "_shards": {
    "total": 6,
    "successful": 6,
    "failed": 0
  },
  "hits": {
    "total": 10,
    "max_score": 1,
    "hits": [
      {
        "_index": ".kibana",
        "_type": "config",
        "_id": "5.2.0",
        "_score": 1,
        "_source": {
          "buildNum": 14695
        }
      }
    ]
  }
}
```

took：整个搜索请求花费了多少毫秒

hits.total：本次搜索，返回了几条结果
hits.max_score：本次搜索的所有结果中，最大的相关度分数是多少，每一条document对于search的相关度，越相关，_score分数越大，排位越靠前
hits.hits：默认查询前10条数据，完整数据，_score降序排序

shards：shards fail的条件（primary和replica全部挂掉），不影响其他shard。默认情况下来说，一个搜索请求，会打到一个index的所有primary shard上去，当然了，每个primary shard都可能会有一个或多个replic shard，所以请求也可以到primary shard的其中一个replica shard上去。

timeout：默认无timeout，latency平衡completeness，手动指定timeout，timeout查询执行机制

timeout=10ms，timeout=1s，timeout=1m
GET /_search?timeout=10m

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/04/1635956182.png" alt="timeout机制详解" style="zoom:75%;" />

# 35. 初识搜索引擎_multi-index&multi-type搜索模式解析以及搜索原理初步图解

## 35.1 multi-index和multi-type搜索模式

告诉你如何一次性搜索多个index和多个type下的数据

/_search：所有索引，所有type下的所有数据都搜索出来
/index1/_search：指定一个index，搜索其下所有type的数据
/index1,index2/_search：同时搜索两个index下的数据
/*1,*2/_search：按照通配符去匹配多个索引
/index1/type1/_search：搜索一个index下指定的type的数据
/index1/type1,type2/_search：可以搜索一个index下多个type的数据
/index1,index2/type1,type2/_search：搜索多个index下的多个type的数据
/_all/type1,type2/_search：_all，可以代表搜索所有index下的指定type的数据

## 35.2 初步图解一下简单的搜索原理

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/04/1635956477.png" alt="初步图解搜索原理" style="zoom:75%;" />

# 36. 初始搜索引擎_分页搜索以及deep paging性能问题深度图解揭秘

## 36.1 讲解如何使用es进行分页搜索的语法

size，from

GET /_search?size=10
GET /_search?size=10&from=0
GET /_search?size=10&from=20

分页的上机实验

GET /test_index/test_type/_search

"hits": {
    "total": 9,
    "max_score": 1,

}

我们假设将这9条数据分成3页，每一页是3条数据，来实验一下这个分页搜索的效果

GET /test_index/test_type/_search?from=0&size=3

第一页：id=8,6,4

GET /test_index/test_type/_search?from=3&size=3

第二页：id=2,自动生成,7

GET /test_index/test_type/_search?from=6&size=3

第三页：id=1,11,3

## 36.2 什么是deep paging问题？为什么会产生这个问题，它的底层原理是什么？

deep paging性能问题，以及原理深度图解揭秘，很高级的知识点。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/04/1636030214.png" alt="deep paging图解" style="zoom:75%;" />

# 37. 初识搜索引擎_快速掌握query string search语法以及_all metadata原理揭秘

## 37.1 query string基础语法

GET /test_index/test_type/_search?q=test_field:test
GET /test_index/test_type/_search?q=+test_field:test
GET /test_index/test_type/_search?q=-test_field:test

一个是掌握q=field:search content的语法，还有一个是掌握+和-的含义

## 37.2 _all metadata的原理和作用

GET /test_index/test_type/_search?q=test

直接可以搜索所有的field，任意一个field包含指定的关键字就可以搜索出来。我们在进行中搜索的时候，难道是对document中的每一个field都进行一次搜索吗？不是的

es中的\_all元数据，在建立索引的时候，我们插入一条document，它里面包含了多个field，此时，es会自动将多个field的值，全部用字符串的方式串联起来，变成一个长的字符串，作为\_all field的值，同时建立索引。

后面如果在搜索的时候，没有对某个field指定搜索，就默认搜索_all field，其中是包含了所有field的值的。

举个例子：

```json
{
  "name": "jack",
  "age": 26,
  "email": "jack@sina.com",
  "address": "guamgzhou"
}
```

"jack 26 jack@sina.com guangzhou"，作为这一条document的_all field的值，同时进行分词后建立对应的倒排索引。

生产环境不使用。

# 38. 初识搜索引擎_用一个例子告诉你mapping到底是什么

插入几条数据，让es自动为我们建立一个索引。

PUT /website/article/1

```json
{
  "post_date": "2017-01-01",
  "title": "my first article",
  "content": "this is my first article in this website",
  "author_id": 11400
}
```

PUT /website/article/2

```json
{
  "post_date": "2017-01-02",
  "title": "my second article",
  "content": "this is my second article in this website",
  "author_id": 11400
}
```

PUT /website/article/3

```json
{
  "post_date": "2017-01-03",
  "title": "my third article",
  "content": "this is my third article in this website",
  "author_id": 11400
}
```

尝试各种搜索

GET /website/article/\_search?q=2017			3条结果       (\_all搜索)     

GET /website/article/\_search?q=2017-01-01        	3条结果 (\_all搜索)   

GET /website/article/\_search?q=post_date:2017-01-01   	1条结果（post_date field搜索）

GET /website/article/\_search?q=post_date:2017         	1条结果（post_date field搜索）

查看es自动建立的mapping，带出什么是mapping的知识点。

**自动或手动为index中的type建立的一种数据结构和相关配置，简称为mapping**。

**dynamic mapping，自动为我们建立index，创建type，以及type对应的mapping，mapping中包含了每个field对应的数据类型，以及如何分词等设置。**

我们当然，后面会讲解，也可以手动在创建数据之前，先创建index和type，以及type对应的mapping。

GET /website/_mapping/article

```json
{
  "website": {
    "mappings": {
      "article": {
        "properties": {
          "author_id": {
            "type": "long"
          },
          "content": {
            "type": "text",
            "fields": {
              "keyword": {
                "type": "keyword",
                "ignore_above": 256
              }
            }
          },
          "post_date": {
            "type": "date"
          },
          "title": {
            "type": "text",
            "fields": {
              "keyword": {
                "type": "keyword",
                "ignore_above": 256
              }
            }
          }
        }
      }
    }
  }
}
```

搜索结果为什么不一致，因为es自动建立mapping的时候，设置了不同的field不同的data type。不同的data type的分词、搜索等行为是不一样的。所以出现了_all field和post_date field的搜索表现完全不一样。

# 39. 初识搜索引擎_精确匹配与全文搜索的对比分析

## 39.1 exact value

2017-01-01，exact value，搜索的时候，必须输入2017-01-01，才能搜索出来。
如果你输入一个01，是搜索不出来的。

## 39.2 full text

- 缩写 vs. 全程：cn vs. china
- 格式转化：like liked likes
- 大小写：Tom vs tom
- 同义词：like vs love

2017-01-01，2017 01 01，搜索2017，或者01，都可以搜索出来

china，搜索cn，也可以将china搜索出来

likes，搜索like，也可以将likes搜索出来

Tom，搜索tom，也可以将Tom搜索出来

like，搜索love，同义词，也可以将like搜索出来。

就不是说单纯的只是匹配完整的一个值，而是可以对值进行拆分词语后（分词）进行匹配，也可以通过缩写、时态、大小写、同义词等进行匹配。

# 40. 初识搜索引擎_倒排索引核心原理快速揭秘

doc1：I really liked my small dogs, and I think my mom also liked them.

doc2：He never liked any dogs, so I hope that my mom will not expect me to liked him.

分词，初步的倒排索引的建立：

| word   | doc1 | doc2 |
| ------ | ---- | ---- |
| I      | *    | *    |
| really | *    |      |
| liked  | *    | *    |
| my     | *    | *    |
| small  | *    |      |
| dogs   | *    | *    |
| and    | *    |      |
| think  | *    |      |
| mom    | *    | *    |
| also   | *    |      |
| them   | *    |      |
| He     |      | *    |
| never  |      | *    |
| any    |      | *    |
| so     |      | *    |
| hope   |      | *    |
| that   |      | *    |
| will   |      | *    |
| not    |      | *    |
| expect |      | *    |
| me     |      | *    |
| to     |      | *    |
| him    |      | *    |

搜索：

mother like little dog，不可能有任何结果。

mother
like
little
dog

这个是不是我们想要的搜索结果 ？？？绝对不是，因为在我们看来，mother和mom有区别吗？同义词，都是妈妈的意思。like和liked有区别吗？没有，都是喜欢的意思，只不过一个是现在时，一个是过去时。little和small有区别吗？同义词，都是小小的。dog和dogs有区别吗？狗，只不过一个是单数，一个是复数。

normalization，建立倒排索引的时候，会执行一个操作，也就是说对拆分出的各个单词进行相应的处理，以提升后面搜索的时候能够搜索到相关联的文档的概率。

**时态的转换，单复数的转换，同义词的转换，大小写的转换**

mom -->  mother
liked -->  like
small -->  little
dogs -->  dog

重新建立倒排索引，加入normalization，再次用mother liked little dog搜索，就可以搜索到了。

| word   | doc1 | doc2 |                  |
| ------ | ---- | ---- | ---------------- |
| I      | *    | *    |                  |
| really | *    |      | liked --> like   |
| like   | *    | *    |                  |
| my     | *    | *    |                  |
| little | *    |      | small --> little |
| dog    | *    | *    | dogs --> dog     |
| and    | *    |      |                  |
| think  | *    |      |                  |
| mom    | *    | *    |                  |
| also   | *    |      |                  |
| them   | *    |      |                  |
| He     |      | *    |                  |
| never  |      | *    |                  |
| any    |      | *    |                  |
| so     |      | *    |                  |
| hope   |      | *    |                  |
| that   |      | *    |                  |
| will   |      | *    |                  |
| not    |      | *    |                  |
| expect |      | *    |                  |
| me     |      | *    |                  |
| to     |      | *    |                  |
| him    |      | *    |                  |

mother like little dog，分词，**normalization**

mother	--> mom
like	--> like
little	--> little
dog	--> dog

doc1和doc2都会搜索出来

doc1：I really liked my small dogs, and I think my mom also liked them.
doc2：He never liked any dogs, so I hope that my mom will not expect me to liked him.

# 41. 初识搜索引擎_分词器的内部组成到底是什么，以及内置分词器的介绍

## 41.1 什么是分词器

切分词语，normalization（提升recall召回率）

给你一段句子，然后将这段句子拆分成一个一个的单个的单词，同时对每个单词进行normalization（时态转换，单复数转换），分词器
recall，召回率：搜索的时候，增加能够搜索到的结果的数量

character filter：在一段文本进行分词之前，先进行预处理，比如说最常见的就是，过滤html标签（\<span>hello\<span> --> hello），& --> and（I&you --> I and you）
tokenizer：分词，hello you and me --> hello, you, and, me
token filter：lowercase，stop word，synonymom，dogs --> dog，liked --> like，Tom --> tom，a/the/an --> 干掉，mother --> mom，small --> little

一个分词器，很重要，将一段文本进行各种处理，最后处理好的结果才会拿去建立倒排索引。

## 41.2 内置分词器的介绍

Set the shape to semi-transparent by calling set_trans(5)

standard analyzer：set, the, shape, to, semi, transparent, by, calling, set_trans, 5（默认的是standard）

simple analyzer：set, the, shape, to, semi, transparent, by, calling, set, trans

whitespace analyzer：Set, the, shape, to, semi-transparent, by, calling, set_trans(5)

language analyzer（特定的语言的分词器，比如说，english，英语分词器）：set, shape, semi, transpar, call, set_tran, 5

# 42. 初识搜索引擎_query string的分词以及mapping引入案例遗留问题的大揭秘

## 42.1 query string分词

query string必须以和index建立时相同的analyzer进行分词
query string对exact value和full text的区别对待

date：exact value
_all：full text

比如我们有一个document，其中有一个field，包含的value是：hello you and me，建立倒排索引。

我们要搜索这个document对应的index，搜索文本是hell me，这个搜索文本就是query string。

query string，默认情况下，es会使用它对应的field建立倒排索引时相同的分词器去进行分词，分词和normalization，只有这样，才能实现正确的搜索。

我们建立倒排索引的时候，将dogs --> dog，结果你搜索的时候，还是一个dogs，那不就搜索不到了吗？所以搜索的时候，那个dogs也必须变成dog才行。才能搜索到。

知识点：不同类型的field，可能有的就是full text，有的就是exact value。

post_date，date：exact value
_all：full text，分词，normalization

## 42.2 mapping引入案例遗留问题大揭秘

（1）GET /_search?q=2017

搜索的是_all field，document所有的field都会拼接成一个大串（“2017-01-02 my second article this is my second article in this website 11400”），进行分词。

|      | doc1 | doc2 | doc3 |
| ---- | ---- | ---- | ---- |
| 2017 | *    | *    | *    |
| 01   | *    |      |      |
| 02   |      | *    |      |
| 03   |      |      | *    |

_all，2017，自然会搜索到3个docuemnt



（2）GET /_search?q=2017-01-01

_all，2017-01-01，query string**会用跟建立倒排索引一样的分词器去进行分词**

2017
01
01

（3）GET /_search?q=post_date:2017-01-01

date，会作为exact value去建立索引

|            | doc1 | doc2 | doc3 |
| ---------- | ---- | ---- | ---- |
| 2017-01-01 | *    |      |      |
| 2017-01-02 |      | *    |      |
| 2017-01-03 |      |      | *    |

post_date:2017-01-01，2017-01-01，**doc1一条document**

（4）GET /_search?q=post_date:2017，这个在这里不讲解，因为是es 5.2以后做的一个优化。

## 42.3 测试分词器

GET /_analyze

```json
{
  "analyzer": "standard",
  "text": "Text to analyze"
}
```

# 43. 初识搜索引擎_什么是mapping再次回炉透彻理解

（1）往es里面直接插入数据，es会自动建立索引，同时建立type以及对应的mapping。

（2）mapping中就自动定义了每个field的数据类型。

（3）不同的数据类型（比如说text和date），可能有的是exact value，有的是full text。

（4）exact value，在建立倒排索引的时候，分词的时候，是将整个值一起作为一个关键词建立到倒排索引中的；full text，会经历各种各样的处理，分词，normaliztion（时态转换，同义词转换，大小写转换），才会建立到倒排索引中。

（5）同时呢，exact value和full text类型的field就决定了，在一个搜索过来的时候，对exact value field或者是full text field进行搜索的行为也是不一样的，会跟建立倒排索引的行为保持一致；比如说exact value搜索的时候，就是直接按照整个值进行匹配，full text query string，也会进行分词和normalization再去倒排索引中去搜索。

（6）可以用es的dynamic mapping，让其自动建立mapping，包括自动设置数据类型；也可以提前手动创建index和type的mapping，自己对各个field进行设置，包括数据类型，包括索引行为，包括分词器，等等。

**mapping，就是index的type的元数据，每个type都有一个自己的mapping，决定了数据类型，建立倒排索引的行为，还有进行搜索的行为。**

# 44. 初识搜索引擎_mapping的核心数据类型以及dynamic mapping

## 44.1 核心的数据类型

string
byte，short，integer，long
float，double
boolean
date

## 44.2 dynamic mapping

true or false	-->	boolean
123		-->	long
123.45		-->	double
2017-01-01	-->	date
"hello world"	-->	string/text

## 44.3 查看mapping

GET /index/_mapping/type

# 45. 初识搜索引擎_定制string类型数据如何建立索引以及分词

## 45.1 如何建立索引

analyzed
not_analyzed
no

## 45.2 修改mapping

**只能创建index时手动建立mapping，或者新增field mapping，但是不能update field mapping**

PUT /website

```json
{
  "mappings": {
    "article": {
      "properties": {
        "author_id": {
          "type": "long"
        },
        "title": {
          "type": "text",
          "analyzer": "english"
        },
        "content": {
          "type": "text"
        },
        "post_date": {
          "type": "date"
        },
        "publisher_id": {
          "type": "text",
          "index": "not_analyzed"
        }
      }
    }
  }
}
```

PUT /website

```json
# 尝试去修改mapping
{
  "mappings": {
    "article": {
      "properties": {
        "author_id": {
          "type": "text"
        }
      }
    }
  }
}
# 返回结果，报错
{
  "error": {
    "root_cause": [
      {
        "type": "index_already_exists_exception",
        "reason": "index [website/co1dgJ-uTYGBEEOOL8GsQQ] already exists",
        "index_uuid": "co1dgJ-uTYGBEEOOL8GsQQ",
        "index": "website"
      }
    ],
    "type": "index_already_exists_exception",
    "reason": "index [website/co1dgJ-uTYGBEEOOL8GsQQ] already exists",
    "index_uuid": "co1dgJ-uTYGBEEOOL8GsQQ",
    "index": "website"
  },
  "status": 400
}
```

PUT /website/_mapping/article

```json
{
  "properties" : {
    "new_field" : {
      "type" :    "string",
      "index":    "not_analyzed"
    }
  }
}
```

## 45.3 测试mapping

GET /website/_analyze

```json
{
  "field": "content",
  "text": "my-dogs" 
}
```

GET website/_analyze

```json
# keyword 类型不能被分词
{
  "field": "new_field",
  "text": "my dogs"
}
# 尝试去分词，结果报错
{
  "error": {
    "root_cause": [
      {
        "type": "remote_transport_exception",
        "reason": "[4onsTYV][127.0.0.1:9300][indices:admin/analyze[s]]"
      }
    ],
    "type": "illegal_argument_exception",
    "reason": "Can't process field [new_field], Analysis requests are only supported on tokenized fields"
  },
  "status": 400
}
```

# 46. 初识搜索引擎_mapping复杂数据类型以及object类型数据底层结构大揭秘

## 46.1 multivalue field

{ "tags": [ "tag1", "tag2" ]}

建立索引时与string是一样的，数据类型不能混

## 46.2 empty field

null，[]，[null]

## 46.3 object field

PUT /company/employee/1

```json
{
  "address": {
    "country": "china",
    "province": "guangdong",
    "city": "guangzhou"
  },
  "name": "jack",
  "age": 27,
  "join_date": "2017-01-01"
}
```

address：object类型

```json
{
  "company": {
    "mappings": {
      "employee": {
        "properties": {
          "address": {
            "properties": {
              "city": {
                "type": "text",
                "fields": {
                  "keyword": {
                    "type": "keyword",
                    "ignore_above": 256
                  }
                }
              },
              "country": {
                "type": "text",
                "fields": {
                  "keyword": {
                    "type": "keyword",
                    "ignore_above": 256
                  }
                }
              },
              "province": {
                "type": "text",
                "fields": {
                  "keyword": {
                    "type": "keyword",
                    "ignore_above": 256
                  }
                }
              }
            }
          },
          "age": {
            "type": "long"
          },
          "join_date": {
            "type": "date"
          },
          "name": {
            "type": "text",
            "fields": {
              "keyword": {
                "type": "keyword",
                "ignore_above": 256
              }
            }
          }
        }
      }
    }
  }
}

{
  "address": {
    "country": "china",
    "province": "guangdong",
    "city": "guangzhou"
  },
  "name": "jack",
  "age": 27,
  "join_date": "2017-01-01"
}
#   ====>
{
    "name":            [jack],
    "age":          [27],
    "join_date":      [2017-01-01],
    "address.country":         [china],
    "address.province":   [guangdong],
    "address.city":  [guangzhou]
}

{
    "authors": [
        { "age": 26, "name": "Jack White"},
        { "age": 55, "name": "Tom Jones"},
        { "age": 39, "name": "Kitty Smith"}
    ]
}

{
    "authors.age":    [26, 55, 39],
    "authors.name":   [jack, white, tom, jones, kitty, smith]
}
```

# 47. 初始搜索引擎_search api的基础语法介绍

## 47.1 search api的基本语法

GET /search
{}

GET /index1,index2/type1,type2/search
{}

GET /_search
{
  "from": 0,
  "size": 10
}

## 47.2 http协议中get是否可以带上request body

HTTP协议，一般不允许get请求带上request body，但是因为get更加适合描述查询数据的操作，因此还是这么用了

GET /_search?from=0&size=10

POST /_search
{
  "from":0,
  "size":10
}

碰巧，很多浏览器，或者是服务器，也都支持GET+request body模式

如果遇到不支持的场景，也可以用POST /_search

# 48. 初始搜索引擎_快速上机动手实战Query DSL搜索语法

## 48.1 一个例子让你明白什么是Query DSL

GET /_search

```json
{
    "query": {
        "match_all": {}
    }
}
```

## 48.2 Query DSL的基本语法

```json
{
    QUERY_NAME: {
        ARGUMENT: VALUE,
        ARGUMENT: VALUE,...
    }
}

{
    QUERY_NAME: {
        FIELD_NAME: {
            ARGUMENT: VALUE,
            ARGUMENT: VALUE,...
        }
    }
}
```

示例：

GET /test_index/test_type/_search 

```json
{
  "query": {
    "match": {
      "test_field": "test"
    }
  }
}
```

## 48.3 如何组合多个搜索条件

搜索需求：title必须包含elasticsearch，content可以包含elasticsearch也可以不包含，author_id必须不为111

```json
{
  "took": 1,
  "timed_out": false,
  "_shards": {
    "total": 5,
    "successful": 5,
    "failed": 0
  },
  "hits": {
    "total": 3,
    "max_score": 1,
    "hits": [
      {
        "_index": "website",
        "_type": "article",
        "_id": "2",
        "_score": 1,
        "_source": {
          "title": "my hadoop article",
          "content": "hadoop is very bad",
          "author_id": 111
        }
      },
      {
        "_index": "website",
        "_type": "article",
        "_id": "1",
        "_score": 1,
        "_source": {
          "title": "my elasticsearch article",
          "content": "es is very bad",
          "author_id": 110
        }
      },
      {
        "_index": "website",
        "_type": "article",
        "_id": "3",
        "_score": 1,
        "_source": {
          "title": "my elasticsearch article",
          "content": "es is very goods",
          "author_id": 111
        }
      }
    ]
  }
}
```

GET /website/article/_search

```json
{
  "query": {
    "bool": {
      "must": [
        {
          "match": {
            "title": "elasticsearch"
          }
        }
      ],
      "should": [
        {
          "match": {
            "content": "elasticsearch"
          }
        }
      ],
      "must_not": [
        {
          "match": {
            "author_id": 111
          }
        }
      ]
    }
  }
}
```

GET /test_index/_search

```json
{
    "query": {
            "bool": {
                "must": { "match":   { "name": "tom" }},
                "should": [
                    { "match":       { "hired": true }},
                    { "bool": {
                        "must":      { "match": { "personality": "good" }},
                        "must_not":  { "match": { "rude": true }}
                    }}
                ],
                "minimum_should_match": 1
            }
    }
}
```

# 49. 初识搜索引擎_filter与query深入对比解密：相关度，性能

## 49.1 filter与query示例

PUT /company/employee/2

```json
{
  "address": {
    "country": "china",
    "province": "jiangsu",
    "city": "nanjing"
  },
  "name": "tom",
  "age": 30,
  "join_date": "2016-01-01"
}

```

PUT /company/employee/3

```json
{
  "address": {
    "country": "china",
    "province": "shanxi",
    "city": "xian"
  },
  "name": "marry",
  "age": 35,
  "join_date": "2015-01-01"
}
```

搜索请求：年龄必须大于等于30，同时join_date必须是2016-01-01

GET /company/employee/_search

```json
{
  "query": {
    "bool": {
      "must": [
        {
          "match": {
            "join_date": "2016-01-01"
          }
        }
      ],
      "filter": {
        "range": {
          "age": {
            "gte": 30
          }
        }
      }
    }
  }
}
```

## 49.2 filter与query对比大解密

filter，仅仅只是按照搜索条件过滤出需要的数据而已，**不计算任何相关度分数，对相关度没有任何影响**。
query，会去**计算每个document相对于搜索条件的相关度，并按照相关度进行倒序排序**。

一般来说，如果你是在进行搜索，需要将最匹配搜索条件的数据先返回，那么用query；如果你只是要根据一些条件筛选出一部分数据，不关注其排序，那么用filter。
除非是你的这些搜索条件，你希望越符合这些搜索条件的document越排在前面返回，那么这些搜索条件要放在query中；如果你不希望一些搜索条件来影响你的document排序，那么就放在filter中即可。

## 49.3 filter与query性能

**filter，不需要计算相关度分数，不需要按照相关度分数进行排序，同时还有内置的自动cache最常使用filter的数据。**
**query，相反，要计算相关度分数，按照分数进行排序，而且无法cache结果。**

# 50. 初识搜索引擎_上机动手实战常用的各种query搜索语法

## 50.1 match all

GET /_search

```json
{
    "query": {
        "match_all": {}
    }
}
```

## 50.2 match

GET /_search

```json
{
    "query": { "match": { "title": "my elasticsearch article" }}
}
```

## 50.3 multi match

GET /test_index/test_type/_search

```json
{
  "query": {
    "multi_match": {
      "query": "test",
      "fields": ["test_field", "test_field1"]
    }
  }
}
```

## 50.4 range query

GET /company/employee/_search 

```json
{
  "query": {
    "range": {
      "age": {
        "gte": 30
      }
    }
  }
}
```

## 50.5 term query

GET /test_index/test_type/_search 

```json
{
  "query": {
    "term": {
      # 必需完全匹配到不会被分词的field
      "test_field": "test hello"
    }
  }
}
```

## 50.6 terms query

GET /_search

```json
{
    "query": { "terms": { "tag": [ "search", "full_text", "nosql" ] }}
}
```

## 50.7 exist query

（2.x中的查询，现在已经不提供了）

# 51. 初识搜索引擎_上机动手实战多搜索条件组合查询

GET /website/article/_search

```json
{
  "query": {
    "bool": {
      "must": [
        {
          "match": {
            "title": "elasticsearch"
          }
        }
      ],
      "should": [
        {
          "match": {
            "content": "elasticsearch"
          }
        }
      ],
      "must_not": [
        {
          "match": {
            "author_id": 111
          }
        }
      ]
    }
  }
}

{
    "bool": {
        "must":     { "match": { "title": "how to make millions" }},
        "must_not": { "match": { "tag":   "spam" }},
        "should": [
            { "match": { "tag": "starred" }}
        ],
        "filter": {
          "range": { "date": { "gte": "2014-01-01" }} 
        }
    }
}
```

bool：
must，must_not，should，filter

每个子查询都会计算一个document针对它的相关度分数，然后bool综合所有分数，合并为一个分数，当然filter是不会计算分数的。

```json
{
    "bool": {
        "must":     { "match": { "title": "how to make millions" }},
        "must_not": { "match": { "tag":   "spam" }},
        "should": [
            { "match": { "tag": "starred" }}
        ],
        "filter": {
          "bool": { 
              "must": [
                  { "range": { "date": { "gte": "2014-01-01" }}},
                  { "range": { "price": { "lte": 29.99 }}}
              ],
              "must_not": [
                  { "term": { "category": "ebooks" }}
              ]
          }
        }
    }
}
```

GET /company/employee/_search 

```json
{
  "query": {
    "constant_score": {
      "filter": {
        "range": {
          "age": {
            "gte": 30
          }
        }
      }
    }
  }
}
```

# 52. 初识搜索引擎_上机动手实战如何定位不合法的搜索以及其原因

GET /test_index/test_type/_validate/query?explain

```json
{
  "query": {
    "math": {
      "test_field": "test"
    }
  }
}

{
  "valid": false,
  "error": "org.elasticsearch.common.ParsingException: no [query] registered for [math]"
}
```

GET /test_index/test_type/_validate/query?explain

```json
{
  "query": {
    "match": {
      "test_field": "test"
    }
  }
}

{
  "valid": true,
  "_shards": {
    "total": 1,
    "successful": 1,
    "failed": 0
  },
  "explanations": [
    {
      "index": "test_index",
      "valid": true,
      "explanation": "+test_field:test #(#_type:test_type)"
    }
  ]
}
```

一般用在那种特别复杂庞大的搜索下，比如你一下子写了上百行的搜索，这个时候可以先用validate api去验证一下，搜索是否合法。

# 53. 初识搜素引擎_上机动手实战如何定制搜索结果的排序规则

## 53.1 默认排序规则

默认情况下，是按照_score降序排序的

然而，某些情况下，可能没有有用的_score，比如说filter

GET /_search

```json
{
    "query" : {
        "bool" : {
            "filter" : {
                "term" : {
                    "author_id" : 1
                }
            }
        }
    }
}
```

当然，也可以是constant_score

GET /_search

```json
{
    "query" : {
        "constant_score" : {
            "filter" : {
                "term" : {
                    "author_id" : 1
                }
            }
        }
    }
}
```

## 53.2 定制排序规则

GET /company/employee/_search 

```json
{
  "query": {
    "constant_score": {
      "filter": {
        "range": {
          "age": {
            "gte": 30
          }
        }
      }
    }
  },
  "sort": [
    {
      "join_date": {
        "order": "asc"
      }
    }
  ]
}
```

# 54. 初识搜索引擎_解密如何将一个field索引两次来解决字符串排序问题

如果对一个string field进行排序，结果往往不准确，因为分词后是多个单词，再排序就不是我们想要的结果了

通常解决方案是，**将一个string field建立两次索引，一个分词，用来进行搜索；一个不分词，用来进行排序**

PUT /website 

```json
{
  "mappings": {
    "article": {
      "properties": {
        "title": {
          # 分词，用来搜索的
          "type": "text",
          # 不分词，用来排序的
          "fields": {
            "raw": {
              "type": "string",
              "index": "not_analyzed"
            }
          },
          "fielddata": true
        },
        "content": {
          "type": "text"
        },
        "post_date": {
          "type": "date"
        },
        "author_id": {
          "type": "long"
        }
      }
    }
  }
}
```

PUT /website/article/1

```json
{
  "title": "first article",
  "content": "this is my second article",
  "post_date": "2017-01-01",
  "author_id": 110
}
{
  "took": 2,
  "timed_out": false,
  "_shards": {
    "total": 5,
    "successful": 5,
    "failed": 0
  },
  "hits": {
    "total": 3,
    "max_score": 1,
    "hits": [
      {
        "_index": "website",
        "_type": "article",
        "_id": "2",
        "_score": 1,
        "_source": {
          "title": "first article",
          "content": "this is my first article",
          "post_date": "2017-02-01",
          "author_id": 110
        }
      },
      {
        "_index": "website",
        "_type": "article",
        "_id": "1",
        "_score": 1,
        "_source": {
          "title": "second article",
          "content": "this is my second article",
          "post_date": "2017-01-01",
          "author_id": 110
        }
      },
      {
        "_index": "website",
        "_type": "article",
        "_id": "3",
        "_score": 1,
        "_source": {
          "title": "third article",
          "content": "this is my third article",
          "post_date": "2017-03-01",
          "author_id": 110
        }
      }
    ]
  }
}
```

GET /website/article/_search

```json
{
  "query": {
    "match_all": {}
  },
  "sort": [
    {
      "title.raw": {
        "order": "desc"
      }
    }
  ]
}
```

# 55. 初识搜索引擎_相关度评分TF&IDF算法独家解密

## 55.1 算法介绍

relevance score算法，简单来说，就是计算出，一个索引中的文本，与搜索文本，他们之间的关联匹配程度

Elasticsearch使用的是 term frequency/inverse document frequency算法，简称为TF/IDF算法。

简单来说：一个词语在一篇文章中出现次数越多, 同时在所有文档中出现次数越少, 越能够代表该文章。



Term frequency：**搜索文本中的各个词条在field文本中出现了多少次，出现次数越多，就越相关**。

搜索请求：hello world

doc1：hello you, and world is very good
doc2：hello, how are you



Inverse document frequency：搜索文本中的各个词条在整个索引的所有文档中出现了多少次，出现的次数越多，就越不相关。

搜索请求：hello world

doc1：hello, today is very good
doc2：hi world, how are you

比如说，在index中有1万条document，hello这个单词在所有的document中，一共出现了1000次；world这个单词在所有的document中，一共出现了100次。

doc2更相关



Field-length norm：field长度，field越长，相关度越弱

搜索请求：hello world

doc1：{ "title": "hello article", "content": "babaaba 1万个单词" }
doc2：{ "title": "my article", "content": "blablabala 1万个单词，hi world" }

hello world在整个index中出现的次数是一样多的

doc1更相关，title field更短

## 55.2 _score是如何被计算出来的

GET /test_index/test_type/_search?explain

```json
{
  "query": {
    "match": {
      "test_field": "test hello"
    }
  }
}
```

```json
{
  "took": 6,
  "timed_out": false,
  "_shards": {
    "total": 5,
    "successful": 5,
    "failed": 0
  },
  "hits": {
    "total": 4,
    "max_score": 1.595089,
    "hits": [
      {
        "_shard": "[test_index][2]",
        "_node": "4onsTYVZTjGvIj9_spWz2w",
        "_index": "test_index",
        "_type": "test_type",
        "_id": "20",
        "_score": 1.595089,
        "_source": {
          "test_field": "test hello"
        },
        "_explanation": {
          "value": 1.595089,
          "description": "sum of:",
          "details": [
            {
              "value": 1.595089,
              "description": "sum of:",
              "details": [
                {
                  "value": 0.58279467,
                  "description": "weight(test_field:test in 0) [PerFieldSimilarity], result of:",
                  "details": [
                    {
                      "value": 0.58279467,
                      "description": "score(doc=0,freq=1.0 = termFreq=1.0\n), product of:",
                      "details": [
                        {
                          "value": 0.6931472,
                          "description": "idf, computed as log(1 + (docCount - docFreq + 0.5) / (docFreq + 0.5)) from:",
                          "details": [
                            {
                              "value": 2,
                              "description": "docFreq",
                              "details": []
                            },
                            {
                              "value": 4,
                              "description": "docCount",
                              "details": []
                            }
                          ]
                        },
                        {
                          "value": 0.840795,
                          "description": "tfNorm, computed as (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * fieldLength / avgFieldLength)) from:",
                          "details": [
                            {
                              "value": 1,
                              "description": "termFreq=1.0",
                              "details": []
                            },
                            {
                              "value": 1.2,
                              "description": "parameter k1",
                              "details": []
                            },
                            {
                              "value": 0.75,
                              "description": "parameter b",
                              "details": []
                            },
                            {
                              "value": 1.75,
                              "description": "avgFieldLength",
                              "details": []
                            },
                            {
                              "value": 2.56,
                              "description": "fieldLength",
                              "details": []
                            }
                          ]
                        }
                      ]
                    }
                  ]
                },
                {
                  "value": 1.0122943,
                  "description": "weight(test_field:hello in 0) [PerFieldSimilarity], result of:",
                  "details": [
                    {
                      "value": 1.0122943,
                      "description": "score(doc=0,freq=1.0 = termFreq=1.0\n), product of:",
                      "details": [
                        {
                          "value": 1.2039728,
                          "description": "idf, computed as log(1 + (docCount - docFreq + 0.5) / (docFreq + 0.5)) from:",
                          "details": [
                            {
                              "value": 1,
                              "description": "docFreq",
                              "details": []
                            },
                            {
                              "value": 4,
                              "description": "docCount",
                              "details": []
                            }
                          ]
                        },
                        {
                          "value": 0.840795,
                          "description": "tfNorm, computed as (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * fieldLength / avgFieldLength)) from:",
                          "details": [
                            {
                              "value": 1,
                              "description": "termFreq=1.0",
                              "details": []
                            },
                            {
                              "value": 1.2,
                              "description": "parameter k1",
                              "details": []
                            },
                            {
                              "value": 0.75,
                              "description": "parameter b",
                              "details": []
                            },
                            {
                              "value": 1.75,
                              "description": "avgFieldLength",
                              "details": []
                            },
                            {
                              "value": 2.56,
                              "description": "fieldLength",
                              "details": []
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "value": 0,
              "description": "match on required clause, product of:",
              "details": [
                {
                  "value": 0,
                  "description": "# clause",
                  "details": []
                },
                {
                  "value": 1,
                  "description": "*:*, product of:",
                  "details": [
                    {
                      "value": 1,
                      "description": "boost",
                      "details": []
                    },
                    {
                      "value": 1,
                      "description": "queryNorm",
                      "details": []
                    }
                  ]
                }
              ]
            }
          ]
        }
      },
      {
        "_shard": "[test_index][2]",
        "_node": "4onsTYVZTjGvIj9_spWz2w",
        "_index": "test_index",
        "_type": "test_type",
        "_id": "6",
        "_score": 0.58279467,
        "_source": {
          "test_field": "tes test"
        },
        "_explanation": {
          "value": 0.58279467,
          "description": "sum of:",
          "details": [
            {
              "value": 0.58279467,
              "description": "sum of:",
              "details": [
                {
                  "value": 0.58279467,
                  "description": "weight(test_field:test in 0) [PerFieldSimilarity], result of:",
                  "details": [
                    {
                      "value": 0.58279467,
                      "description": "score(doc=0,freq=1.0 = termFreq=1.0\n), product of:",
                      "details": [
                        {
                          "value": 0.6931472,
                          "description": "idf, computed as log(1 + (docCount - docFreq + 0.5) / (docFreq + 0.5)) from:",
                          "details": [
                            {
                              "value": 2,
                              "description": "docFreq",
                              "details": []
                            },
                            {
                              "value": 4,
                              "description": "docCount",
                              "details": []
                            }
                          ]
                        },
                        {
                          "value": 0.840795,
                          "description": "tfNorm, computed as (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * fieldLength / avgFieldLength)) from:",
                          "details": [
                            {
                              "value": 1,
                              "description": "termFreq=1.0",
                              "details": []
                            },
                            {
                              "value": 1.2,
                              "description": "parameter k1",
                              "details": []
                            },
                            {
                              "value": 0.75,
                              "description": "parameter b",
                              "details": []
                            },
                            {
                              "value": 1.75,
                              "description": "avgFieldLength",
                              "details": []
                            },
                            {
                              "value": 2.56,
                              "description": "fieldLength",
                              "details": []
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "value": 0,
              "description": "match on required clause, product of:",
              "details": [
                {
                  "value": 0,
                  "description": "# clause",
                  "details": []
                },
                {
                  "value": 1,
                  "description": "*:*, product of:",
                  "details": [
                    {
                      "value": 1,
                      "description": "boost",
                      "details": []
                    },
                    {
                      "value": 1,
                      "description": "queryNorm",
                      "details": []
                    }
                  ]
                }
              ]
            }
          ]
        }
      },
      {
        "_shard": "[test_index][3]",
        "_node": "4onsTYVZTjGvIj9_spWz2w",
        "_index": "test_index",
        "_type": "test_type",
        "_id": "7",
        "_score": 0.5565415,
        "_source": {
          "test_field": "test client 2"
        },
        "_explanation": {
          "value": 0.5565415,
          "description": "sum of:",
          "details": [
            {
              "value": 0.5565415,
              "description": "sum of:",
              "details": [
                {
                  "value": 0.5565415,
                  "description": "weight(test_field:test in 0) [PerFieldSimilarity], result of:",
                  "details": [
                    {
                      "value": 0.5565415,
                      "description": "score(doc=0,freq=1.0 = termFreq=1.0\n), product of:",
                      "details": [
                        {
                          "value": 0.6931472,
                          "description": "idf, computed as log(1 + (docCount - docFreq + 0.5) / (docFreq + 0.5)) from:",
                          "details": [
                            {
                              "value": 1,
                              "description": "docFreq",
                              "details": []
                            },
                            {
                              "value": 2,
                              "description": "docCount",
                              "details": []
                            }
                          ]
                        },
                        {
                          "value": 0.8029196,
                          "description": "tfNorm, computed as (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * fieldLength / avgFieldLength)) from:",
                          "details": [
                            {
                              "value": 1,
                              "description": "termFreq=1.0",
                              "details": []
                            },
                            {
                              "value": 1.2,
                              "description": "parameter k1",
                              "details": []
                            },
                            {
                              "value": 0.75,
                              "description": "parameter b",
                              "details": []
                            },
                            {
                              "value": 2.5,
                              "description": "avgFieldLength",
                              "details": []
                            },
                            {
                              "value": 4,
                              "description": "fieldLength",
                              "details": []
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "value": 0,
              "description": "match on required clause, product of:",
              "details": [
                {
                  "value": 0,
                  "description": "# clause",
                  "details": []
                },
                {
                  "value": 1,
                  "description": "_type:test_type, product of:",
                  "details": [
                    {
                      "value": 1,
                      "description": "boost",
                      "details": []
                    },
                    {
                      "value": 1,
                      "description": "queryNorm",
                      "details": []
                    }
                  ]
                }
              ]
            }
          ]
        }
      },
      {
        "_shard": "[test_index][1]",
        "_node": "4onsTYVZTjGvIj9_spWz2w",
        "_index": "test_index",
        "_type": "test_type",
        "_id": "8",
        "_score": 0.25316024,
        "_source": {
          "test_field": "test client 2"
        },
        "_explanation": {
          "value": 0.25316024,
          "description": "sum of:",
          "details": [
            {
              "value": 0.25316024,
              "description": "sum of:",
              "details": [
                {
                  "value": 0.25316024,
                  "description": "weight(test_field:test in 0) [PerFieldSimilarity], result of:",
                  "details": [
                    {
                      "value": 0.25316024,
                      "description": "score(doc=0,freq=1.0 = termFreq=1.0\n), product of:",
                      "details": [
                        {
                          "value": 0.2876821,
                          "description": "idf, computed as log(1 + (docCount - docFreq + 0.5) / (docFreq + 0.5)) from:",
                          "details": [
                            {
                              "value": 1,
                              "description": "docFreq",
                              "details": []
                            },
                            {
                              "value": 1,
                              "description": "docCount",
                              "details": []
                            }
                          ]
                        },
                        {
                          "value": 0.88,
                          "description": "tfNorm, computed as (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * fieldLength / avgFieldLength)) from:",
                          "details": [
                            {
                              "value": 1,
                              "description": "termFreq=1.0",
                              "details": []
                            },
                            {
                              "value": 1.2,
                              "description": "parameter k1",
                              "details": []
                            },
                            {
                              "value": 0.75,
                              "description": "parameter b",
                              "details": []
                            },
                            {
                              "value": 3,
                              "description": "avgFieldLength",
                              "details": []
                            },
                            {
                              "value": 4,
                              "description": "fieldLength",
                              "details": []
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
              ]
            },
            {
              "value": 0,
              "description": "match on required clause, product of:",
              "details": [
                {
                  "value": 0,
                  "description": "# clause",
                  "details": []
                },
                {
                  "value": 1,
                  "description": "*:*, product of:",
                  "details": [
                    {
                      "value": 1,
                      "description": "boost",
                      "details": []
                    },
                    {
                      "value": 1,
                      "description": "queryNorm",
                      "details": []
                    }
                  ]
                }
              ]
            }
          ]
        }
      }
    ]
  }
}
```

## 55.3 分析一个document是如何被匹配上的

GET /test_index/test_type/6/_explain

```json
{
  "query": {
    "match": {
      "test_field": "test hello"
    }
  }
}
```

# 56. 初识搜索引擎_内核级知识点之doc value初步探秘

**搜索的时候，要依靠倒排索引；排序的时候，需要依靠正排索引**，看到每个document的每个field，然后进行排序，所谓的正排索引，其实就是doc values。

在建立索引的时候，一方面会建立倒排索引，以供搜索用；一方面会建立正排索引，也就是doc values，以供排序，聚合，过滤等操作使用

doc values是被保存在磁盘上的，此时如果内存足够，os会自动将其缓存在内存中，性能还是会很高；如果内存不足够，os会将其写入磁盘上。

doc1: hello world you and me
doc2: hi, world, how are you

倒排索引：用来搜索

| word  | doc1 | doc2 |
| ----- | ---- | ---- |
| hello | *    |      |
| world | *    | *    |
| you   | *    | *    |
| and   | *    |      |
| me    | *    |      |
| hi    |      | *    |
| how   |      | *    |

hello you --> hello, you

hello --> doc1
you --> doc1,doc2

doc1: hello world you and me
doc2: hi, world, how are you

sort by age

doc1: { "name": "jack", "age": 27 }
doc2: { "name": "tom", "age": 30 }

正排索引：用来排序

| document | name | age  |
| -------- | ---- | ---- |
| doc1     | jack | 27   |
| doc2     | tom  | 30   |

# 57. 初识搜索引擎_分布式搜索引擎内核解密之query phase

## 57.1 query phase

（1）搜索请求发送到某一个coordinate node，构构建一个priority queue，长度以paging操作from和size为准，默认为10。
（2）coordinate node将请求转发到所有shard，每个shard本地搜索，并构建一个本地的priority queue。
（3）各个shard将自己的priority queue返回给coordinate node，并构建一个全局的priority queue。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/06/1636129533.png" alt="query phase" style="zoom:75%;" />

## 57.2 replica shard如何提升搜索吞吐量

一次请求要打到所有shard的一个replica/primary上去，如果每个shard都有多个replica，那么同时并发过来的搜索请求可以同时打到其他的replica上去。

# 58. 初识搜索引擎_分布式搜索引擎内核解密之fetch phase

## 58.1 fetch phbase工作流程

（1）coordinate node构建完priority queue之后，就发送mget请求去所有shard上获取对应的document。
（2）各个shard将document返回给coordinate node。
（3）coordinate node将合并后的document结果返回给client客户端。

![fetch phase](http://blog-1259650185.cosbj.myqcloud.com/img/202111/06/1636130050.png)

**一般搜索，如果不加from和size，就默认搜索前10条，按照_score排序**。

# 59. 初识搜索引擎_搜索相关参数梳理以及bouncing results问题解决方案

## 59.1 preference

决定了哪些shard会被用来执行搜索操作

_primary, _primary_first, _local, _only_node:xyz, _prefer_node:xyz, _shards:2,3

bouncing results问题，两个document排序，field值相同；不同的shard上，可能排序不同；每次请求轮询打到不同的replica shard上；每次页面上看到的搜索结果的排序都不一样。这就是bouncing result，也就是跳跃的结果。

搜索的时候，是**轮询将搜索请求发送到每一个replica shard（primary shard），但是在不同的shard上，可能document的排序不同**。

**解决方案就是将preference设置为一个字符串，比如说user_id，让每个user每次搜索的时候，都使用同一个replica shard去执行，就不会看到bouncing results（跳跃结果）了**

## 59.2 timeout

已经讲解过原理了，主要就是限定在一定时间内，将部分获取到的数据直接返回，避免查询耗时过长。

## 59.3 routing

document文档路由，_id路由，routing=user_id，这样的话可以让同一个user对应的数据到一个shard上去。

## 59.4 search_type

default：query_then_fetch
dfs_query_then_fetch，可以提升revelance sort精准度

# 60. 初识搜索引擎_上机动手实战基于scoll技术滚动搜索大量数据

如果一次性要查出来比如10万条数据，那么性能会很差，此时一般会采取用scoll滚动查询，一批一批的查，直到所有数据都查询完处理完。

使用scoll滚动搜索，可以先搜索一批数据，然后下次再搜索一批数据，以此类推，直到搜索出全部的数据来。
scoll搜索会在第一次搜索的时候，保存一个当时的视图快照，之后只会基于该旧的视图快照提供数据搜索，如果这个期间数据变更，是不会让用户看到的。
采用基于_doc进行排序的方式，性能较高。
每次发送scroll请求，我们还需要指定一个scoll参数，指定一个时间窗口，每次搜索请求只要在这个时间窗口内能完成就可以了。

GET /test_index/test_type/_search?scroll=1m

```json
{
  "query": {
    "match_all": {}
  },
  "sort": [ "_doc" ],
  "size": 3
}
# 返回结果
{
  "_scroll_id": "DnF1ZXJ5VGhlbkZldGNoBQAAAAAAACxeFjRvbnNUWVZaVGpHdklqOV9zcFd6MncAAAAAAAAsYBY0b25zVFlWWlRqR3ZJajlfc3BXejJ3AAAAAAAALF8WNG9uc1RZVlpUakd2SWo5X3NwV3oydwAAAAAAACxhFjRvbnNUWVZaVGpHdklqOV9zcFd6MncAAAAAAAAsYhY0b25zVFlWWlRqR3ZJajlfc3BXejJ3",
  "took": 5,
  "timed_out": false,
  "_shards": {
    "total": 5,
    "successful": 5,
    "failed": 0
  },
  "hits": {
    "total": 10,
    "max_score": null,
    "hits": [
      {
        "_index": "test_index",
        "_type": "test_type",
        "_id": "8",
        "_score": null,
        "_source": {
          "test_field": "test client 2"
        },
        "sort": [
          0
        ]
      },
      {
        "_index": "test_index",
        "_type": "test_type",
        "_id": "6",
        "_score": null,
        "_source": {
          "test_field": "tes test"
        },
        "sort": [
          0
        ]
      },
      {
        "_index": "test_index",
        "_type": "test_type",
        "_id": "AVp4RN0bhjxldOOnBxaE",
        "_score": null,
        "_source": {
          "test_content": "my test"
        },
        "sort": [
          0
        ]
      }
    ]
  }
}
```

获得的结果会有一个scoll_id，下一次再发送scoll请求的时候，必须带上这个scoll_id

GET /_search/scroll

```json
{
    "scroll": "1m", 
    "scroll_id" : "DnF1ZXJ5VGhlbkZldGNoBQAAAAAAACxeFjRvbnNUWVZaVGpHdklqOV9zcFd6MncAAAAAAAAsYBY0b25zVFlWWlRqR3ZJajlfc3BXejJ3AAAAAAAALF8WNG9uc1RZVlpUakd2SWo5X3NwV3oydwAAAAAAACxhFjRvbnNUWVZaVGpHdklqOV9zcFd6MncAAAAAAAAsYhY0b25zVFlWWlRqR3ZJajlfc3BXejJ3"
}
```

第二批：11,4,7
第三批：3,2,1
第四批：20

scoll，看起来挺像分页的，但是其实使用场景不一样。分页主要是用来一页一页搜索，给用户看的；scoll主要是用来一批一批检索数据，让系统进行处理的。

# 61. 索引管理_快速上机动手实战创建、修改以及删除索引

## 61.1 为什么我们要手动创建索引？

## 61.2 创建索引

创建索引的语法

PUT /my_index

```json
{
    "settings": { ... any settings ... },
    "mappings": {
        "type_one": { ... any mappings ... },
        "type_two": { ... any mappings ... },
        ...
    }
}
```



创建索引的示例

PUT /my_index

```json
{
  "settings": {
    "number_of_shards": 1,
    "number_of_replicas": 0
  },
  "mappings": {
    "my_type": {
      "properties": {
        "my_field": {
          "type": "text"
        }
      }
    }
  }
}
```

## 61.3 修改索引

PUT /my_index/_settings

```json
{
    "number_of_replicas": 1
}
```

## 61.4 删除索引

DELETE /my_index
DELETE /index_one,index_two
DELETE /index_*
DELETE /\_all

elasticsearch.yml
action.destructive_requires_name: true

# 62. 索引管理_快速上机动手实战修改分词器以及定制自己的分词器

## 62.1 默认的分词器

standard

standard tokenizer：以单词边界进行切分
standard token filter：什么都不做
lowercase token filter：将所有字母转换为小写
stop token filer（默认被禁用）：移除停用词，比如a the it等等

## 62.2 修改分词器的设置

启用english停用词token filter

PUT /my_index

````json
{
  "settings": {
    "analysis": {
      "analyzer": {
        "es_std": {
          "type": "standard",
          "stopwords": "_english_"
        }
      }
    }
  }
}
````

GET /my_index/_analyze

```json
{
  "analyzer": "standard", 
  "text": "a dog is in the house"
}
```

GET /my_index/_analyze

```json
{
  "analyzer": "es_std",
  "text":"a dog is in the house"
}
```

## 62.3 定制化自己的分词器

PUT /my_index

```json
{
  "settings": {
    "analysis": {
      "char_filter": {
        "&_to_and": {
          "type": "mapping",
          "mappings": ["&=> and"]
        }
      },
      "filter": {
        "my_stopwords": {
          "type": "stop",
          "stopwords": ["the", "a"]
        }
      },
      "analyzer": {
        "my_analyzer": {
          "type": "custom",
          "char_filter": ["html_strip", "&_to_and"],
          "tokenizer": "standard",
          "filter": ["lowercase", "my_stopwords"]
        }
      }
    }
  }
}
```

GET /my_index/_analyze

```json
{
  "text": "tom&jerry are a friend in the house, <a>, HAHA!!",
  "analyzer": "my_analyzer"
}
```

PUT /my_index/_mapping/my_type

```json
{
  "properties": {
    "content": {
      "type": "text",
      "analyzer": "my_analyzer"
    }
  }
}
```

# 63. 索引管理_内核级知识点：深入探秘type底层数据结构

type，是一个index中用来区分类似的数据的，类似的数据，但是可能有不同的fields，而且有不同的属性来控制索引建立、分词器
field的value，在底层的lucene中建立索引的时候，全部是opaque bytes类型，不区分类型的。
lucene是没有type的概念的，在document中，实际上将type作为一个document的field来存储，即\_type，es通过_type来进行type的过滤和筛选。
一个index中的多个type，实际上是放在一起存储的，因此一个index下，不能有多个type重名，而类型或者其他设置不同的，因为那样是无法处理的。

```json
{
   "ecommerce": {
      "mappings": {
         "elactronic_goods": {
            "properties": {
               "name": {
                  "type": "string",
               },
               "price": {
                  "type": "double"
               },
	       "service_period": {
		  "type": "string"
	       }			
            }
         },
         "fresh_goods": {
            "properties": {
               "name": {
                  "type": "string",
               },
               "price": {
                  "type": "double"
               },
	       "eat_period": {
		  "type": "string"
	       }
            }
         }
      }
   }
}

{
  "name": "geli kongtiao",
  "price": 1999.0,
  "service_period": "one year"
}

{
  "name": "aozhou dalongxia",
  "price": 199.0,
  "eat_period": "one week"
}
```

在底层的存储是这样子的。。。。

```json
{
   "ecommerce": {
      "mappings": {
        "_type": {
          "type": "string",
          "index": "not_analyzed"
        },
        "name": {
          "type": "string"
        },
        "price": {
          "type": "double"
        },
        "service_period": {
          "type": "string"
        },
        "eat_period": {
          "type": "string"
        }
      }
   }
}

{
  "_type": "elactronic_goods",
  "name": "geli kongtiao",
  "price": 1999.0,
  "service_period": "one year",
  # 包含其他type的field，但是是空的
  "eat_period": ""
}

{
  "_type": "fresh_goods",
  "name": "aozhou dalongxia",
  "price": 199.0,
  # 空的
  "service_period": "",
  "eat_period": "one week"
}
```

最佳实践，将类似结构的type放在一个index下，这些type应该有多个field是相同的。

假如说，你将两个type的field完全不同，放在一个index下，那么就每条数据都至少有一半的field在底层的lucene中是空值，会有严重的性能问题。

# 64. 索引管理_mapping root object深入剖析

## 64.1 root object

就是某个type对应的mapping json，包括了properties，metadata（\_id，\_source，_type），settings（analyzer），其他settings（比如include_in_all）

PUT /my_index

```json
{
  "mappings": {
    "my_type": {
      "properties": {}
    }
  }
}
```

## 64.2 properties

type，index，analyzer

PUT /my_index/_mapping/my_type

```json
{
  "properties": {
    "title": {
      "type": "text"
    }
  }
}
```

## 64.3 _source

就是document对应的原始的json对象。

好处

（1）查询的时候，直接可以拿到完整的document，不需要先拿document id，再发送一次请求拿document
（2）partial update基于\_source实现
（3）reindex时，直接基于\_source实现，不需要从数据库（或者其他外部存储）查询数据再修改
（4）可以基于_source定制返回field
（5）debug query更容易，因为可以直接看到\_source

如果不需要上述好处，可以禁用_source

PUT /my_index/_mapping/my_type2

```json
{
  "_source": {"enabled": false}
}
```

## 64.4 _all

将所有field打包在一起，作为一个\_all field，建立索引。**没指定任何field进行搜索时，就是使用_all field在搜索**。

PUT /my_index/_mapping/my_type3

```json
{
  "_all": {"enabled": false}
}
```

也可以在field级别设置include_in_all field，设置是否要将field的值包含在_all field中

PUT /my_index/_mapping/my_type4

```json
{
  "properties": {
    "my_field": {
      "type": "text",
      "include_in_all": false
    }
  }
}
```

## 64.5 标识性metadata

\_index，\_type，_id

# 65. 索引管理_定制化自己的dynamic mapping策略

## 65.1 定制dynamic策略

- true：遇到陌生字段，就进行dynamic mapping
- false：遇到陌生字段，就忽略
- strict：遇到陌生字段，就报错

PUT /my_index

```json
{
  "mappings": {
    "my_type": {
      "dynamic": "strict",
      "properties": {
        "title": {
          "type": "text"
        },
        "address": {
          "type": "object",
          "dynamic": "true"
        }
      }
    }
  }
}
```

PUT /my_index/my_type/1

```json
# 尝试新增doc的时候加一个新的字段
{
  "title": "my article",
  "content": "this is my article",
  "address": {
    "province": "guangdong",
    "city": "guangzhou"
  }
}
# 结果会报错
{
  "error": {
    "root_cause": [
      {
        "type": "strict_dynamic_mapping_exception",
        "reason": "mapping set to strict, dynamic introduction of [content] within [my_type] is not allowed"
      }
    ],
    "type": "strict_dynamic_mapping_exception",
    "reason": "mapping set to strict, dynamic introduction of [content] within [my_type] is not allowed"
  },
  "status": 400
}
```

PUT /my_index/my_type/1

```json
# 这种是ok的
{
  "title": "my article",
  "address": {
    "province": "guangdong",
    "city": "guangzhou"
  }
}
```

GET /my_index/_mapping/my_type

```json
{
  "my_index": {
    "mappings": {
      "my_type": {
        "dynamic": "strict",
        "properties": {
          "address": {
            "dynamic": "true",
            "properties": {
              "city": {
                "type": "text",
                "fields": {
                  "keyword": {
                    "type": "keyword",
                    "ignore_above": 256
                  }
                }
              },
              "province": {
                "type": "text",
                "fields": {
                  "keyword": {
                    "type": "keyword",
                    "ignore_above": 256
                  }
                }
              }
            }
          },
          "title": {
            "type": "text"
          }
        }
      }
    }
  }
}
```

## 65.2 定制dynamic mapping策略

（1）date_detection

默认会按照一定格式识别date，比如yyyy-MM-dd。但是如果某个field先过来一个2017-01-01的值，就会被自动dynamic mapping成date，后面如果再来一个"hello world"之类的值，就会报错。可以手动关闭某个type的date_detection，如果有需要，自己手动指定某个field为date类型。

PUT /my_index/_mapping/my_type

```json
{
    "date_detection": false
}
```

（2）定制自己的dynamic mapping template（type level）

PUT /my_index

```json
{
    "mappings": {
        "my_type": {
            "dynamic_templates": [
                { "en": {
                      "match":              "*_en", 
                      "match_mapping_type": "string",
                      "mapping": {
                          "type":           "string",
                          "analyzer":       "english"
                      }
                }}
            ]
}}}
```

PUT /my_index/my_type/1

```json
{
  "title": "this is my first article"
}
```

PUT /my_index/my_type/2

```json
{
  "title_en": "this is my first article"
}
```

title没有匹配到任何的dynamic模板，默认就是standard分词器，不会过滤停用词，is会进入倒排索引，用is来搜索是可以搜索到的。
title_en匹配到了dynamic模板，就是english分词器，会过滤停用词，is这种停用词就会被过滤掉，用is来搜索就搜索不到了。

（3）定制自己的default mapping template（index level）

PUT /my_index

```json
{
    "mappings": {
        "_default_": {
            "_all": { "enabled":  false }
        },
        "blog": {
            "_all": { "enabled":  true  }
        }
    }
}
```

# 66. 索引管理_基于scoll滚动搜索和alias别名实现zero downtime reindex

## 66.1 重建索引

一个field的设置是不能被修改的，如果要修改一个Field，那么应该重新按照新的mapping，建立一个index，然后将数据批量查询出来，重新用bulk api写入index中。

批量查询的时候，建议采用scroll api，并且采用多线程并发的方式来reindex数据，每次scoll就查询指定日期的一段数据，交给一个线程即可。

（1）一开始，依靠dynamic mapping，插入数据，但是不小心有些数据是2017-01-01这种日期格式的，所以title这种field被自动映射为了date类型，实际上它应该是string类型的。

PUT /my_index/my_type/3

```json
{
  "title": "2017-01-03"
}

{
  "my_index": {
    "mappings": {
      "my_type": {
        "properties": {
          "title": {
            "type": "date"
          }
        }
      }
    }
  }
}
```

（2）当后期向索引中加入string类型的title值的时候，就会报错。

PUT /my_index/my_type/4

```json
{
  "title": "my first article"
}
# 往date类型field插入string类型，会报错
{
  "error": {
    "root_cause": [
      {
        "type": "mapper_parsing_exception",
        "reason": "failed to parse [title]"
      }
    ],
    "type": "mapper_parsing_exception",
    "reason": "failed to parse [title]",
    "caused_by": {
      "type": "illegal_argument_exception",
      "reason": "Invalid format: \"my first article\""
    }
  },
  "status": 400
}
```

（3）如果此时想修改title的类型，是不可能的。

PUT /my_index/_mapping/my_type

```json
{
  "properties": {
    "title": {
      "type": "text"
    }
  }
}
# 后面再想改title的类型，改不了的，会报错
{
  "error": {
    "root_cause": [
      {
        "type": "illegal_argument_exception",
        "reason": "mapper [title] of different type, current_type [date], merged_type [text]"
      }
    ],
    "type": "illegal_argument_exception",
    "reason": "mapper [title] of different type, current_type [date], merged_type [text]"
  },
  "status": 400
}
```

（4）此时，唯一的办法，就是进行reindex，也就是说，重新建立一个索引，将旧索引的数据查询出来，再导入新索引。

（5）如果说旧索引的名字，是old_index，新索引的名字是new_index，终端java应用，已经在使用old_index在操作了，难道还要去停止java应用，修改使用的index为new_index，才重新启动java应用吗？这个过程中，就会导致java应用停机，可用性降低。

（6）所以说，给java应用一个别名，这个别名是指向旧索引的，java应用先用着，java应用先用goods_index alias来操作，此时实际指向的是旧的my_index。

PUT /my_index/_alias/goods_index

（7）新建一个index，调整其title的类型为string。

PUT /my_index_new

```json
{
  "mappings": {
    "my_type": {
      "properties": {
        "title": {
          "type": "text"
        }
      }
    }
  }
}
```

（8）使用scroll api将数据批量查询出来。

GET /my_index/_search?scroll=1m

```json
{
    "query": {
        "match_all": {}
    },
    "sort": ["_doc"],
    "size":  1
}

{
  "_scroll_id": "DnF1ZXJ5VGhlbkZldGNoBQAAAAAAADpAFjRvbnNUWVZaVGpHdklqOV9zcFd6MncAAAAAAAA6QRY0b25zVFlWWlRqR3ZJajlfc3BXejJ3AAAAAAAAOkIWNG9uc1RZVlpUakd2SWo5X3NwV3oydwAAAAAAADpDFjRvbnNUWVZaVGpHdklqOV9zcFd6MncAAAAAAAA6RBY0b25zVFlWWlRqR3ZJajlfc3BXejJ3",
  "took": 1,
  "timed_out": false,
  "_shards": {
    "total": 5,
    "successful": 5,
    "failed": 0
  },
  "hits": {
    "total": 3,
    "max_score": null,
    "hits": [
      {
        "_index": "my_index",
        "_type": "my_type",
        "_id": "2",
        "_score": null,
        "_source": {
          "title": "2017-01-02"
        },
        "sort": [
          0
        ]
      }
    ]
  }
}
```

（9）采用bulk api将scoll查出来的一批数据，批量写入新索引。

POST /_bulk

```json
{ "index":  { "_index": "my_index_new", "_type": "my_type", "_id": "2" }}
{ "title":    "2017-01-02" }
```

（10）反复循环8~9，查询一批又一批的数据出来，采取bulk api将每一批数据批量写入新索引。

（11）将goods_index alias切换到my_index_new上去，java应用会直接通过index别名使用新的索引中的数据，java应用程序不需要停机，零提交，高可用。

POST /_aliases

```json
{
    "actions": [
        { "remove": { "index": "my_index", "alias": "goods_index" }},
        { "add":    { "index": "my_index_new", "alias": "goods_index" }}
    ]
}
```

（12）直接通过goods_index别名来查询，是否ok。

GET /goods_index/my_type/_search

## 66.2 基于alias对client透明切换index

PUT /my_index_v1/_alias/my_index

client对my_index进行操作

reindex操作，完成之后，切换v1到v2

POST /_aliases

```json
{
    "actions": [
        { "remove": { "index": "my_index_v1", "alias": "my_index" }},
        { "add":    { "index": "my_index_v2", "alias": "my_index" }}
    ]
}
```

# 67. 内核原理探秘_倒排索引组成结构以及其索引不可变原因揭秘

倒排索引，是适合用于进行搜索的。

倒排索引的结构：

（1）包含这个关键词的document list。
（2）包含这个关键词的所有document的数量：IDF（inverse document frequency）。
（3）这个关键词在每个document中出现的次数：TF（term frequency）。
（4）这个关键词在这个document中的次序。
（5）每个document的长度：length norm。
（6）包含这个关键词的所有document的平均长度。

| word  | doc1 | doc2 |
| ----- | ---- | ---- |
| dog   | *    | *    |
| hello | *    |      |
| you   |      | *    |

倒排索引不可变的好处：

（1）不需要锁，提升并发能力，避免锁的问题。
（2）数据不变，一直保存在os cache中，只要cache内存足够。
（3）filter cache一直驻留在内存，因为数据不变。
（4）可以压缩，节省cpu和io开销。

倒排索引不可变的坏处：每次都要重新构建整个索引。

# 69. 内核原理探秘_深度图解剖析document写入原理（buffer，segment，commit）

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/06/1636212399.png" alt="document增删改内核级原理" style="zoom:75%;" />

（1）数据写入内存buffer
（2）buffer写满了以后，达到 commit point，执行commit操作
（3）会把buffer中的数据写入新的index segment，index segment会先写到os cache中
（4）等待在os cache中的index segment被fsync强制刷到磁盘上
（5）当index segment文件刷新到磁盘上后，新的index sgement被打开，原来的index segment就可以供search使用了
（6）buffer被清空，search操作就能到index segment上搜到了

每次commit point时，会有一个.del文件，标记了哪些segment中的哪些document被标记为deleted了。
搜索的时候，会依次查询所有的segment，从旧的到新的，比如被修改过的document，在旧的segment中，会标记为deleted，在新的segment中会有其新的数据。

# 70. 内核原理探秘_优化写入流程实现NRT近实时（filesystem cache，refresh）

现有流程的问题，每次都必须等待fsync将segment刷入磁盘，才能将segment打开供search使用，这样的话，从一个document写入，到它可以被搜索，可能会超过1分钟！！！这就不是近实时的搜索了！！！主要瓶颈在于fsync实际发生磁盘IO写数据进磁盘，是很耗时的。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/06/1636213078.png" alt="NRT写入优化" style="zoom:75%;" />

写入流程别改进如下：

（1）数据写入buffer
（2）每隔一定时间，buffer中的数据被写入segment文件，但是先写入os cache
（3）**只要segment写入os cache，那就直接打开供search使用，不立即执行commit**

**数据写入os cache，并被打开供搜索的过程，叫做refresh，默认是每隔1秒refresh一次**。也就是说，**每隔一秒就会将buffer中的数据写入一个新的index segment file，先写入os cache中。所以，es是近实时的**，数据写入到可以被搜索，默认是1秒。

POST /my_index/_refresh，可以手动refresh，一般不需要手动执行，没必要，让es自己搞就可以了。

比如说，我们现在的时效性要求，比较低，只要求一条数据写入es，一分钟以后才让我们搜索到就可以了，那么就可以调整refresh interval。

PUT /my_index

```json
{
  "settings": {
    "refresh_interval": "30s" 
  }
}
```

# 71. 内核原理探秘_继续优化写入流程实现durability可靠存储（translog，flush）

再次优化的写入流程

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/06/1636214053.png" alt="终极版本的es数据写入流程" style="zoom:75%;" />

（1）数据写入buffer缓冲和translog日志文件
（2）每隔一秒钟，buffer中的数据被写入新的segment file，并进入os cache，此时segment被打开并供search使用
（3）buffer被清空
（4）重复1~3，新的segment不断添加，buffer不断被清空，而translog中的数据不断累加
（5）当translog长度达到一定程度的时候，commit操作发生
  （5-1）buffer中的所有数据写入一个新的segment，并写入os cache，打开供search使用
  （5-2）buffer被清空
  （5-3）一个commit ponit被写入磁盘，标明了所有的index segment
  （5-4）filesystem cache中的所有index segment file缓存数据，被fsync强行刷到磁盘上
  （5-5）现有的translog被清空，创建一个新的translog

**基于translog和commit point，如何进行数据恢复**

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636214913.png" alt="commit point+translog进行数据恢复" style="zoom:75%;" />

fsync+清空translog，就是flush，默认每隔30分钟flush一次，或者当translog过大的时候，也会flush。 

POST /my_index/_flush，一般来说别手动flush，让它自动执行就可以了

translog，每隔5秒被fsync一次到磁盘上。在一次增删改操作之后，当fsync在primary shard和replica shard都成功之后，那次增删改操作才会成功。

**但是这种在一次增删改时强行fsync translog可能会导致部分操作比较耗时，也可以允许部分数据丢失，设置异步fsync translog（允许5秒数据丢失）**。

PUT /my_index/_settings

```json
{
    "index.translog.durability": "async",
    "index.translog.sync_interval": "5s"
}
```

# 72. 内核原理探秘_最后优化写入流程实现海量磁盘文件合并（segment merge，optimize）

每秒一个segment file，文件过多，而且每次search都要搜索所有的segment，很耗时。

默认会在后台执行segment merge操作，在merge的时候，被标记为deleted的document也会被彻底物理删除。

<img src="http://blog-1259650185.cosbj.myqcloud.com/img/202111/07/1636215197.png" alt="segment merge" style="zoom:75%;" />

每次merge操作的执行流程：

（1）选择一些有相似大小的segment，merge成一个大的segment
（2）将新的segment flush到磁盘上去
（3）写一个新的commit point，包括了新的segment，并且排除旧的那些segment
（4）将新的segment打开供搜索
（5）将旧的segment删除

POST /my_index/_optimize?max_num_segments=1，尽量不要手动执行，让它自动默认执行就可以了。

