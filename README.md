# 🐬 Doris Dev Helper

> 给 Doris 开发者的“一键脚本”合集：  
> 5 分钟构建镜像，1 条命令拉起任意规模的集群。

---

## 🧰 目录
1. docker-build.sh: 一键打包output目录下的 Doris FE & BE 镜像  
2. start-doris.sh: 一行命令启动Doris集群  

---

## 1. docker-build.sh

### 📌 作用
把 **本地 Doris 编译产物** 打成 **Docker 镜像**  
- `doris.fe:3-local`
- `doris.be:3-local`

### 🚀 快速上手
```bash
# 0) 克隆本仓库（或直接拷脚本）
git clone https://github.com/yourname/doris-dev-helper.git

# 1) 把脚本放到 Doris 源码目录
cp doris-dev-helper/docker-build.sh $DORIS_HOME/docker/runtime/

# 2) 编译 Doris 后，打包镜像
cd $DORIS_HOME/docker/runtime
./docker-build.sh -o /path/to/doris/output

# 3) 验证
docker image ls | grep doris
# 应出现：
# doris.be   3-local
# doris.fe   3-local
```

### ⚙️ 参数

| 参数              | 必填 | 示例                      | 说明                                     |
| ----------------- | ---- | ------------------------- | ---------------------------------------- |
| `-o`              | ✅    | `/home/lisa/doris/output` | Doris 编译输出目录                       |
| `-v`              | ❎    | `3xxx`or`2xxx`            | 版本号必须为3或2开头，用于指定java的版本 |
| `--rebuild-base`  | ❎    | `--rebuild-base`          | 强制重新构建Doris的base镜像              |
| `--clean-version` | ❎    | `--clean -v 3.x.x`        | 删除某个镜像                             |
| `--clean-base`    | ❎    | `--clean-base`            | 删除base镜像                             |

## 2. start-doris.sh

### 📌 作用

用 **Docker 容器** 启动 Doris 集群，可单机、可多集群，支持自定义网络。

### 🚀 常见用法

#### 1️⃣ 启动 **单集群**

1 个 FE + 3 个 BE

```bash
./start-doris.sh -c 3-local -f 1 -b 3
```

#### 2️⃣ 启动 **两个隔离集群**

- cluster1：1 FE + 3 BE
- cluster2：1 FE + 1 BE

> 两个集群 **不同网段**，彼此 **不可访问**

```bash
./start-doris.sh -c 3-local -m 'cluster1=1fe3be,cluster2=1fe1be'
```

#### 3️⃣ 启动 **两个互通集群**

同上规模，但放在 **同一自定义网络**，方便做CCR测试。

```bash
./start-doris.sh \
  -c 3-local \
  -m 'cluster1=1fe3be,cluster2=1fe1be' \
  -X \
  -N doris_shared \
  -S 172.30.0.0/16
```

### ⚙️ 参数速查

```sh
-c  镜像 tag（必填）            例: 3-local
-f  FE 节点数（单集群模式）      例: 1
-b  BE 节点数（单集群模式）      例: 3
-m  多集群描述（与 -f/-b 互斥）  例: 'cluster1=1fe3be,cluster2=1fe1be'
-X  使用共享网络（需配合 -N/-S）
-N  共享网络名称                例: doris_shared
-S  共享网段                    例: 172.30.0.0/16
```

