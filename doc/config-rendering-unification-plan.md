# 配置生成统一化实施方案

> 状态：待实施  
> 目标：统一服务端、客户端配置的生成入口、变量处理、校验和写入流程。  
> 约束：`.env` 与 `.env.client` 继续分开；不引入 Python、Node、Ansible 等新运行时依赖。

## 1. 背景

当前仓库存在三条配置处理路径：

1. 服务端配置由 `Makefile` 直接调用 `envsubst` 生成。
2. 客户端配置由 `scripts/gen-client-config.sh` 使用 `envsubst + jq` 生成。
3. systemd unit 由 `scripts/install-systemd.sh` 直接执行无范围的 `envsubst` 后写入 `/etc/systemd/system/`。

这些路径在变量提取、条件处理、输出写入和校验方面不一致，并存在以下问题：

- systemd 的无范围 `envsubst` 会把 `nginx.service.template` 中属于 systemd 的 `$MAINPID` 当成环境变量替换，通常会得到空字符串。
- JSON 模板直接插入字符串变量，密码等值包含双引号、反斜杠时可能破坏 JSON。
- `XRAY_SERVERNAMES`、`XRAY_SHORTIDS` 要求在 `.env` 中携带 JSON 引号，配置数据与 JSON 表达方式耦合。
- 服务端与客户端使用不同的变量提取规则。
- 渲染直接覆盖正式输出；中途失败可能留下不完整配置。
- 客户端 jq 程序内联在 Bash 脚本中，不利于单独维护和测试。

## 2. 设计决策

### 2.1 统一流程，不强求统一模板语言

所有配置统一通过一个 Bash 入口生成，但按配置格式选择合适的后端：

- Nginx、TOML、YAML：受限 `envsubst`。
- JSON：使用 jq 注入有类型的值、生成数组并处理条件配置。
- systemd unit：当前没有项目变量，作为静态文件直接安装，不执行 `envsubst`。

统一后的流程为：

```text
Makefile
  -> scripts/config/render.sh
  -> 加载对应 env
  -> 校验变量
  -> 渲染到临时文件
  -> 格式及语义校验
  -> 原子替换正式输出
```

### 2.2 `.env` 与 `.env.client` 继续分开

`.env` 保存服务端及部署参数，包括 REALITY 私钥、ML-DSA seed、镜像和二进制下载地址。

`.env.client` 只保存客户端建立连接所需的信息，包括服务器地址、端口、UUID、连接密码和 REALITY 公钥。

不合并两者，避免服务端私钥进入客户端配置分发范围。本次不实现自动同步；以后如增加 `make client-env-from-server`，必须采用显式白名单，且不得复制：

- `XRAY_REALITY_PRIVATE_KEY`
- `XRAY_REALITY_MLDSA65_SEED`
- 服务端镜像变量
- 二进制下载地址
- 其他仅服务端使用的秘密

### 2.3 保留模板就近存放

模板继续放在所属服务目录，不集中移动：

```text
server/hy2/config/config.toml.template
server/nginx/acme.conf.template
server/xray/config/config.json.template
server/sing-box/config/config.json.template
client/config/config.json.template
client/hy2-config/config.yaml.template
```

统一的是渲染机制和入口，不改变模板的可发现性。

### 2.4 保持现有命令兼容

新增统一命令：

```bash
make config-server
make config-client
make config-all
make config-check
```

保留旧入口并改为别名：

```make
template: config-server
client-template: config-client
```

`config-all` 必须同时存在 `.env` 和 `.env.client`；缺少任一文件都应明确失败，不静默跳过。

## 3. 目标目录结构

新增：

```text
scripts/config/
├── render.sh
├── lib.sh
├── validate.sh
└── filters/
    ├── xray.jq
    ├── sing-box-server.jq
    └── sing-box-client.jq
```

职责说明：

- `render.sh`：统一命令行入口，接受 `server`、`client`、`all`、`check`。
- `lib.sh`：env 加载、变量提取、临时文件、受限替换、原子写入等公共函数。
- `validate.sh`：必填项、端口、布尔值、UUID、残留模板变量及输出格式校验。
- `filters/*.jq`：JSON 字段注入、数组转换和条件裁剪。

目标数量较少，不增加 TSV、YAML 等 manifest。目标映射直接写成 Bash 函数，避免再引入一种配置格式。

## 4. 渲染接口

`scripts/config/render.sh` 提供：

```bash
scripts/config/render.sh server
scripts/config/render.sh client
scripts/config/render.sh all
scripts/config/render.sh check
```

建议的内部函数接口：

```bash
load_env ENV_FILE
require_commands envsubst jq
validate_server_env
validate_client_env
render_text ENV_FILE TEMPLATE OUTPUT VARIABLE_LIST
render_json ENV_FILE TEMPLATE FILTER OUTPUT
validate_json OUTPUT
atomic_replace TEMP_FILE OUTPUT
```

`render_server` 和 `render_client` 显式列出目标，不通过目录扫描隐式发现文件。例如：

```bash
render_server() {
  render_text \
    "$ROOT_DIR/.env" \
    "$ROOT_DIR/server/hy2/config/config.toml.template" \
    "$ROOT_DIR/server/hy2/config/config.toml" \
    '${HY2_ADDR} ${HY2_PASSWORD} ${HY2_WARP_ADDR}'

  render_json \
    "$ROOT_DIR/.env" \
    "$ROOT_DIR/server/xray/config/config.json.template" \
    "$ROOT_DIR/scripts/config/filters/xray.jq" \
    "$ROOT_DIR/server/xray/config/config.json"
}
```

实际实现可调整参数形式，但必须保持目标和变量白名单显式可审查。

## 5. 文本配置渲染

所有项目模板变量统一使用花括号形式：

```text
${MYSITE}
${HY2_PASSWORD}
${CLIENT_HY2_SERVER}
```

程序自身变量保持原样：

```text
$host
$MAINPID
```

调用 `envsubst` 时必须传入明确的变量列表，禁止：

```bash
envsubst < template > output
```

渲染必须先写同目录临时文件，再移动为正式输出。推荐流程：

```bash
output_dir=$(dirname "$output")
mkdir -p "$output_dir"
temp_file=$(mktemp "$output_dir/.render.XXXXXX")
envsubst "$variables" < "$template" > "$temp_file"
validate_rendered_text "$temp_file" "$variables"
mv -f "$temp_file" "$output"
```

使用 `trap` 清理未完成的临时文件。不得先删除已有正式输出。

## 6. JSON 配置渲染

JSON 中的动态值不得继续依赖在引号内直接执行字符串替换。jq 注入规则如下：

- 字符串使用 `--arg`。
- 数字、布尔值和数组使用 `--argjson`，或在 jq 中明确执行 `tonumber`、布尔转换和 `split`。
- 条件协议的删除、WARP 规则裁剪等结构变化继续由 jq 完成。
- 所有 jq filter 从 Bash 中移到独立 `.jq` 文件。

示例：

```bash
jq \
  --arg password "$SINGBOX_TUIC_PASSWORD" \
  --argjson port "$SINGBOX_TUIC_PORT" \
  '.inbounds[0].listen_port = $port
   | .inbounds[0].users[0].password = $password' \
  "$template" > "$temp_file"
```

端口在传给 `--argjson` 前必须先检查为十进制整数且位于 `1..65535`。

### 6.1 Xray 数组变量

将：

```dotenv
XRAY_SERVERNAMES="www.microsoft.com","microsoft.com"
XRAY_SHORTIDS="aabbccdd","ffee5678"
```

改为纯数据：

```dotenv
XRAY_SERVERNAMES=www.microsoft.com,microsoft.com
XRAY_SHORTIDS=aabbccdd,ffee5678
```

由 `xray.jq` 转成数组。转换时需要：

- 按逗号分割。
- 去除每项首尾空白。
- 拒绝空数组和空元素。
- 对 short ID 做既有格式要求的校验。

同步更新 `.env.example` 和相关 README 说明。

### 6.2 客户端 JSON

把 `scripts/gen-client-config.sh` 中内联的 jq 程序迁移到 `scripts/config/filters/sing-box-client.jq`。

必须保持现有语义：

- 至少启用一个协议。
- `DEFAULT_OUTBOUND` 必须是已启用协议，否则回退到第一个启用协议。
- 删除所有未启用协议的 outbound。
- `ENABLE_WARP=false` 时删除 WARP outbound 及所有指向 WARP 的路由规则。
- `route.rules` 第一条仍然是 `{ "action": "sniff" }`。
- DNS server 对象保持当前解析语义。
- 生成后确认默认 outbound 确实存在。

DNS 对象应尽量由 jq 使用标量参数构建，不再由 Bash 拼接未转义的 JSON 字符串。

## 7. systemd 调整

当前三个 systemd unit 没有项目配置变量，因此将：

```text
systemd/hy2.service.template
systemd/nginx.service.template
systemd/sing-box.service.template
```

改名为：

```text
systemd/hy2.service
systemd/nginx.service
systemd/sing-box.service
```

`scripts/install-systemd.sh` 不再加载 `.env`，也不再调用 `envsubst`，改用：

```bash
install -m 0644 "$SRC" "$DST"
```

必须确认安装后的 Nginx unit 中仍然包含：

```ini
ExecStop=/bin/kill -s QUIT $MAINPID
```

配置生成和 systemd 安装继续分离：

- `make config-server`：生成仓库内服务配置。
- `make install-systemd`：安装 unit。
- `make sys-template`：复制已经生成并校验的应用配置。

## 8. env 加载约定

本仓库的 env 文件继续定义为 Bash 兼容格式，并由统一函数加载：

```bash
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
```

加载前必须检查文件存在。错误信息应给出对应初始化命令：

- 缺少 `.env`：提示 `make env`。
- 缺少 `.env.client`：提示 `make client-env`。

变量名提取统一使用：

```regex
^[A-Za-z_][A-Za-z0-9_]*=
```

禁止继续使用 `grep -v '^#' | cut -d= -f1`，因为它会把空行和非赋值行带入变量列表。

日志中不得打印 env 完整内容或秘密值。

## 9. 校验规则

### 9.1 通用校验

- 必填变量存在且非空。
- 端口是十进制整数，范围为 `1..65535`。
- `ENABLE_*` 只能是 `true` 或 `false`。
- 至少启用一个客户端协议。
- UUID、REALITY short ID 等按各协议要求校验。
- 输出中不残留本次允许替换的项目变量。
- 发现示例秘密 `123`、`your-strong-password` 时至少给出醒目警告。
- 不把 Nginx `$host`、systemd `$MAINPID` 误报为未替换变量。

### 9.2 格式校验

JSON 输出必须执行：

```bash
jq empty "$output"
```

服务命令可用时，再执行语义检查：

```bash
sing-box check -c "$output"
xray run -test -config "$output"
nginx -t
```

上述命令不存在时，应说明跳过，不能把“没有执行”报告为“验证通过”。

Hysteria 2 如当前版本存在稳定的只检查配置参数，可加入；否则先做变量和基本格式检查，不通过启动服务来验证。

### 9.3 原子性

任一目标渲染或校验失败时：

- 返回非零状态。
- 删除临时文件。
- 保留此前的正式配置不变。
- `config-all` 不得留下半个文件；应先完成全部目标到临时文件，全部通过后再统一提交，或明确实现回滚机制。

推荐 `config-all` 采用“两阶段提交”：

1. 所有目标渲染和验证到临时文件。
2. 全部成功后逐个原子替换正式输出。

## 10. Makefile 调整

新增 `.PHONY` 目标：

```make
config-server:
	$(CUR_DIR)/scripts/config/render.sh server

config-client:
	$(CUR_DIR)/scripts/config/render.sh client

config-all:
	$(CUR_DIR)/scripts/config/render.sh all

config-check:
	$(CUR_DIR)/scripts/config/render.sh check

template: config-server

client-template: config-client
```

从 `Makefile` 删除现有服务端 `envsubst` recipe。Makefile 只负责任务入口，不再负责变量解析、模板渲染或 jq 处理。

如果 Make 不允许同一目标以多处 recipe 重复定义，应调整原目标位置而不是追加第二份定义。

## 11. 迁移步骤

### 阶段一：修复 systemd

1. 将三个 `.service.template` 重命名为 `.service`。
2. 修改 `scripts/install-systemd.sh`，移除 `.env` 加载和 `envsubst`。
3. 使用 `install -m 0644` 安装 unit。
4. 更新所有引用旧文件名的文档和脚本。
5. 验证 `$MAINPID` 原样保留。

### 阶段二：建立统一入口

1. 新建 `scripts/config/render.sh`、`lib.sh`、`validate.sh`。
2. 迁移服务端四个配置目标。
3. 添加临时文件、错误处理和原子替换。
4. 修改 Makefile 并保留旧命令别名。

### 阶段三：迁移客户端

1. 把客户端 jq 程序移到独立 filter。
2. 把 DNS JSON 构建迁入 jq。
3. 将 HY2 YAML 纳入同一渲染入口。
4. 将 `scripts/gen-client-config.sh` 删除，或保留为调用新入口的兼容包装脚本；若 README 或外部使用者可能直接调用，优先保留包装脚本。

### 阶段四：JSON 类型安全

1. 服务端 Xray JSON 改为 jq 安全注入。
2. 服务端 sing-box JSON 改为 jq 安全注入。
3. 客户端 sing-box JSON 改为 jq 安全注入。
4. 修改 Xray 数组变量格式。
5. 用包含引号、反斜杠和特殊字符的测试值验证 JSON 仍合法。

### 阶段五：文档与清理

1. 更新 README 中的配置生成命令。
2. 更新 `.env.example` 与 `.env.client.template` 注释。
3. 确认 `.gitignore` 覆盖全部生成物和临时文件。
4. 检查所有文本文件保持 LF 行尾。

## 12. 验证清单

至少执行以下检查：

```bash
bash -n scripts/config/render.sh
bash -n scripts/config/lib.sh
bash -n scripts/config/validate.sh
bash -n scripts/install-systemd.sh
bash -n scripts/gen-client-config.sh  # 如果保留包装脚本
```

生成配置后：

```bash
jq empty server/xray/config/config.json
jq empty server/sing-box/config/config.json
jq empty client/config/config.json
```

人工检查：

- `server/nginx/conf/acme.conf` 中 `$host` 保留。
- `systemd/nginx.service` 中 `$MAINPID` 保留。
- HY2 ACL 仍使用 `outbound_name(matcher)` 语法。
- 服务端和客户端 sing-box 的 `sniff` 规则顺序不变。
- 客户端禁用协议后不存在对应 outbound。
- `ENABLE_WARP=false` 时不存在 WARP outbound 和指向它的路由规则。
- `DEFAULT_OUTBOUND` 总是指向已存在的 outbound。
- `.env`、`.env.client` 和所有生成物未被 Git 跟踪。
- `git diff --check` 无行尾和空白错误。

建议增加一次特殊字符验证，使用临时 env 文件或测试副本，不修改用户真实配置：

```text
password with spaces
double quote: "
backslash: \
dollar: $
ampersand: &
```

JSON 应正确转义；TOML/YAML 值如不能安全支持某类字符，验证器必须明确拒绝并给出错误，而不是生成损坏配置。

## 13. 验收标准

实施完成需同时满足：

1. `make template` 和 `make client-template` 继续可用。
2. 新增的 `config-server`、`config-client`、`config-all`、`config-check` 可用。
3. Makefile 中不再直接包含配置渲染细节。
4. systemd 安装不再执行无范围 `envsubst`。
5. `$host` 和 `$MAINPID` 均保持字面量。
6. JSON 动态字符串由 jq 安全注入，不依赖裸字符串拼接。
7. 客户端所有协议开关、默认出口和 WARP 行为保持现有语义。
8. 任一渲染或验证失败都不会覆盖已有可用配置。
9. `.env` 与 `.env.client` 保持分离。
10. 不新增 Python、Node、Ansible、Jinja2、gomplate 等依赖。
11. 不改变代理协议、端口默认值、Docker Compose 拓扑或 systemd 服务集合。
12. 所有新增和修改的 Shell、JSON、YAML、TOML、Markdown 文件保持 LF 行尾。

## 14. 非目标

本次不处理：

- 合并 `.env` 和 `.env.client`。
- 自动生成或分发客户端配置。
- 自动推导 REALITY 公钥。
- 修改协议组合、路由策略或 WARP 域名列表。
- 给 systemd 模式增加 Xray。
- 引入完整的配置管理系统。
- 更改证书签发和续期流程。

