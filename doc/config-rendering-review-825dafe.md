# 配置生成统一化审查与修复清单

> 审查提交：`825dafe feat: unify configuration rendering`  
> 对比基线：`0403868`  
> 审查范围：`git diff 0403868...825dafe`  
> 方案来源：`doc/config-rendering-unification-plan.md`  
> 状态：存在阻塞部署的问题，修复后需要重新验证。

## 1. 结论

本次统一化的主体结构已经落地：

- 服务端与客户端进入统一 Bash 渲染入口。
- JSON 使用 jq 做类型安全注入。
- systemd unit 改成静态 `.service`，不再通过无范围 `envsubst` 渲染。
- `$host` 和 `$MAINPID` 得到保留。
- `config-all` 已实现渲染阶段失败时不覆盖现有配置。
- 旧 Make 入口和客户端包装脚本仍可使用。

但当前提交仍有两个 P1 问题：

1. 默认 HY2 服务端配置会生成非法 TOML。
2. 服务语义检查发生在正式配置提交之后，不能兑现“验证成功后再替换”的原子性承诺。

修复优先级建议：先完成 P1，再处理 P2/P3，最后运行本文的完整回归清单。

## 2. P1：HY2 默认配置生成非法 TOML

### 位置

- `.env.example:2`
- `server/hy2/config/config.toml.template:1`
- `scripts/config/lib.sh:31-45`

### 当前行为

`.env.example` 定义：

```dotenv
HY2_ADDR=":10443"
```

统一渲染器通过 Bash 加载 env：

```bash
source "$env_file"
```

加载后 `HY2_ADDR` 的实际值是：

```text
:10443
```

模板当前为：

```toml
listen = ${HY2_ADDR}
```

最终输出：

```toml
listen = :10443
```

该值不是合法 TOML 字符串，Hysteria 无法使用此配置。当前渲染器没有 TOML 语法检查，因此 `make config-server` 仍会报告成功。

### MSYS2 复现结果

使用 `.env.example` 执行：

```bash
make config-server
sed -n '1,4p' server/hy2/config/config.toml
```

得到：

```text
listen = :10443

[tls]
cert = "/etc/ssl/cert.pem"
```

### 建议修复

模板负责 TOML 字符串语法：

```toml
listen = "${HY2_ADDR}"
```

`.env.example` 建议同步改为纯数据：

```dotenv
HY2_ADDR=:10443
```

不要依赖 env 文件中的引号传递到模板输出；Bash `source` 会把引号当成赋值语法，而不是变量值的一部分。

同时增加至少一种基本检查：

- Hysteria CLI 有稳定的只检查参数时，优先调用它。
- 否则增加轻量的 TOML 语法验证方式。
- 如果不增加新依赖，至少对生成的 `listen`、`password`、`addr` 等已知字符串字段进行结构检查，并明确记录该检查不是完整 TOML parser。

### 验收标准

```bash
make env
make config-server
```

生成物第一行必须是：

```toml
listen = ":10443"
```

渲染失败或格式检查失败时，旧的 `server/hy2/config/config.toml` 必须保持不变。

## 3. P1：语义校验晚于正式配置提交

### 位置

- `scripts/config/render.sh:249-277`
- `scripts/config/render.sh:281-304`

### 当前行为

`server`、`client`、`all` 分支执行顺序是：

```text
render
-> JSON 格式检查
-> commit_staged_outputs
-> 报告生成成功
```

sing-box、Xray、Nginx 的语义检查只在单独执行：

```bash
make config-check
```

时运行。

这意味着格式合法但服务无法加载的配置可能先覆盖旧配置。例如无效 REALITY 私钥、服务不支持的字段或协议值，可能通过 `jq empty`，随后被提交到正式路径。

这与方案中的流程不一致：

```text
渲染到临时文件
-> 格式及语义校验
-> 原子替换正式输出
```

### 建议修复

把可用的服务语义检查移动到 staged 文件提交之前：

```text
render_server/render_client
-> validate staged files
-> run available semantic checks against staged paths
-> commit_staged_outputs
```

注意：

- sing-box 和 Xray 应直接检查 staged JSON 路径。
- 不能让检查命令偷偷读取此前的正式输出。
- Nginx 应检查包含 staged `acme.conf` 的临时配置，不能只执行与 staged 文件无关的系统 `nginx -t`。
- 命令不存在时输出 `[SKIP]`，不得声称完成了对应语义验证。
- `config-check` 可以继续保留，用于重新检查已经生成的正式配置。

如果 Nginx staged 检查需要额外主配置，可以在 staging 目录生成最小 `nginx.conf`，通过 `nginx -t -c <temp-config> -p <temp-prefix>` 验证，避免依赖机器当前的系统 Nginx 配置。

### 验收标准

1. 构造格式合法但服务语义无效的 staged 配置。
2. `make config-server` 或 `make config-all` 返回非零。
3. 正式输出的校验和保持不变。
4. 临时 `.render.*` 目录被清理。
5. 服务命令不存在时日志明确显示跳过了什么。

## 4. P2：独立协议地址仍被 `SERVER_ADDR` 阻断

### 位置

- `.env.client.template:1-12`
- `scripts/config/render.sh:32-40`
- `scripts/config/validate.sh:168`

### 当前行为

模板说明 `SERVER_ADDR` 是默认地址，各协议可以通过以下变量单独指定：

```dotenv
CLIENT_VLESS_SERVER=
CLIENT_HY2_SERVER=
CLIENT_TUIC_SERVER=
CLIENT_ANYTLS_SERVER=
```

`resolve_client_defaults` 也实现了这个回退逻辑。但 `validate_client_env` 随后无条件执行：

```bash
require_nonempty SERVER_ADDR || return
```

因此下列合法配置仍会失败：

```dotenv
SERVER_ADDR=
CLIENT_VLESS_SERVER=vless.example.com
CLIENT_HY2_SERVER=hy2.example.com
CLIENT_TUIC_SERVER=tuic.example.com
CLIENT_ANYTLS_SERVER=anytls.example.com
```

MSYS2 复现错误：

```text
Error: SERVER_ADDR must be set and non-empty.
```

### 建议修复

不要无条件要求 `SERVER_ADDR`。完成 fallback 解析后，按实际用途校验：

- 启用 VLESS 时要求 `CLIENT_VLESS_SERVER` 非空。
- 启用 HY2 时要求 `CLIENT_HY2_SERVER` 非空。
- 启用 TUIC 时要求 `CLIENT_TUIC_SERVER` 非空。
- 启用 AnyTLS 时要求 `CLIENT_ANYTLS_SERVER` 非空。
- 独立 Hysteria 2 客户端仍需要相应 HY2 地址。

如果产品决策是强制 `SERVER_ADDR`，则应删除“可完全使用独立地址”的暗示并修改 fallback 设计；不建议这样做，因为旧逻辑允许独立地址。

### 验收标准

- `SERVER_ADDR` 为空、所有实际需要的独立地址都存在时生成成功。
- 某个启用协议既没有独立地址，也没有默认地址时明确失败。
- 禁用协议不因为缺少该协议地址而失败。

## 5. P2：公开渲染接口不可直接执行

### 位置

- `scripts/config/render.sh`
- `doc/config-rendering-unification-plan.md` 第 4、10 节

### 当前行为

文件包含 shebang：

```bash
#!/usr/bin/env bash
```

但 Git 文件模式是：

```text
100644
```

方案声明的接口：

```bash
scripts/config/render.sh server
scripts/config/render.sh client
scripts/config/render.sh all
scripts/config/render.sh check
```

在 Linux checkout 上直接运行会得到 `Permission denied`。Makefile 当前使用 `bash scripts/config/render.sh ...` 绕过了这个问题。

### 建议修复

二选一，并保持文档和实现一致：

1. 推荐：提交 `scripts/config/render.sh` 的可执行位，Makefile 直接调用脚本。
2. 或者：明确所有公开接口都写成 `bash scripts/config/render.sh ...`。

如果保留 `scripts/gen-client-config.sh` 作为“兼容直接调用入口”，也需要明确其执行方式或提交可执行位。

### 验收标准

在 Linux/MSYS2 checkout 中，文档列出的调用方式可以直接成功运行。

## 6. P2：客户端协议组合发生范围扩张

### 位置

- `client/config/config.json.template:43-78`

### 当前行为

本次提交向客户端 sing-box 模板新增了完整的：

- VLESS outbound
- Hysteria 2 outbound

基线模板只有 TUIC、AnyTLS、WARP 和 direct。统一化方案的非目标写明：

```text
不改变代理协议、端口默认值、Docker Compose 拓扑或 systemd 服务集合。
```

仓库说明此前又声称客户端支持 VLESS/HY2，因此这可能是在修复既有实现缺口，而不是无意增加功能。但它仍然超出了“只统一生成方式”的严格范围。

### 处理建议

需要维护者明确选择：

1. 如果 VLESS/HY2 outbound 是有意修复：
   - 保留实现。
   - 单独提交，或在提交信息中明确说明行为扩展。
   - 补充对应协议组合测试。
   - 更新方案文档，说明该范围调整得到确认。
2. 如果本次只允许重构：
   - 从本提交移除新增 outbound。
   - 保持生成结果与基线语义一致。

在没有确认前，不建议静默删除这两个 outbound，因为仓库顶层说明与开关变量已经把它们描述为支持能力。

## 7. P2：AGENTS.md 中的 Bash 检查命令错误

### 位置

- `AGENTS.md:108`

### 当前内容

```bash
bash scripts/config/*.sh -n
```

该命令不会检查所有脚本语法。通配符展开后，Bash 会执行第一个脚本，并把其余路径和 `-n` 当成位置参数。

### 建议修复

改为：

```bash
bash -n scripts/config/render.sh
bash -n scripts/config/lib.sh
bash -n scripts/config/validate.sh
```

或：

```bash
for script in scripts/config/*.sh; do
  bash -n "$script"
done
```

显式列出文件更适合当前规模，也更容易从日志定位失败脚本。

## 8. P3：AGENTS.md 中的 systemd 描述过期

### 位置

- `AGENTS.md:39`
- `AGENTS.md:91`

### 当前问题

第 39 行仍称：

```text
unit 文件由 systemd/*.service.template 渲染到 /etc/systemd/system/
```

但本次实现已改成静态：

```text
systemd/*.service
```

并通过 `install -m 0644` 安装。该描述也与同文件后面的静态 unit 说明矛盾。

### 建议修复

- 删除 `*.service.template` 和“渲染”的说法。
- 明确 unit 是静态文件，安装时不得执行 `envsubst`。
- 第 91 行的“渲染并启用”改为“安装并启用”。
- 保留 `$MAINPID` 必须为字面量的警告。

## 9. 已通过的 MSYS2 检查

测试环境：

```text
MSYS2 runtime 3.6.7
Bash 5.3.9
jq 1.8.1
GNU Make 4.4.1
envsubst available
```

以下检查在 `git archive HEAD` 创建的隔离副本中通过，没有读取或覆盖真实 `.env`：

- `make config-all` 使用两份示例 env 完成生成。
- 三个 JSON 输出通过 `jq empty`。
- Nginx `$host` 保留。
- systemd `$MAINPID` 保留。
- sing-box client 的 sniff 规则保持第一条。
- 默认出站 `tuic` 正确。
- 只启用 TUIC 时，其余协议 outbound 被删除。
- `DEFAULT_OUTBOUND` 指向禁用协议时回退到第一个启用协议。
- WARP 开关正确添加或删除 outbound 和路由规则。
- TLS/HTTPS/UDP DNS 值得到预期对象。
- JSON 密码包含空格、双引号、反斜杠、美元符号和 `&` 时正确转义。
- 客户端渲染后半程失败时，六个旧输出的 SHA-256 均保持不变。
- `make template` 兼容入口可用。
- `scripts/gen-client-config.sh` 兼容包装可用（通过 Bash 调用）。
- `make config-check` 在服务命令缺失时明确输出 `[SKIP]`。
- Git Bash 自带 Bash 的 `bash -n` 检查通过。
- `git diff --check 0403868...825dafe` 通过。

注意：上述“基础生成成功”同时暴露了 HY2 TOML 未被验证的问题；不能把命令退出码为零理解为所有生成配置都可被服务加载。

## 10. 修复后的回归清单

### 10.1 静态检查

```bash
bash -n scripts/config/render.sh
bash -n scripts/config/lib.sh
bash -n scripts/config/validate.sh
bash -n scripts/gen-client-config.sh
bash -n scripts/install-systemd.sh
git diff --check
```

### 10.2 基础生成

在隔离副本或测试 env 中执行：

```bash
make config-server
make config-client
make config-all
make template
make client-template
make config-check
```

### 10.3 输出检查

```bash
jq empty server/xray/config/config.json
jq empty server/sing-box/config/config.json
jq empty client/config/config.json
grep -F '$host' server/nginx/conf/acme.conf
grep -F '$MAINPID' systemd/nginx.service
grep -F 'listen = ":10443"' server/hy2/config/config.toml
```

### 10.4 客户端矩阵

至少覆盖：

1. 仅 VLESS。
2. 仅 HY2。
3. 仅 TUIC。
4. 仅 AnyTLS。
5. 全部协议启用。
6. `DEFAULT_OUTBOUND` 指向已启用协议。
7. `DEFAULT_OUTBOUND` 指向已禁用协议。
8. WARP 开启和关闭。
9. `SERVER_ADDR` fallback。
10. `SERVER_ADDR` 为空但独立协议地址齐全。
11. 启用协议缺少默认地址和独立地址。

每种配置都要确认：

- enabled outbound 存在。
- disabled outbound 不存在。
- `route.final` 指向现有 outbound。
- remote DNS detour 指向默认 outbound。
- sniff 规则保持第一条。
- WARP 关闭时没有任何规则引用 WARP。

### 10.5 特殊字符

JSON 字符串至少覆盖：

```text
space
"
\
$
&
```

TOML/YAML 无法安全支持的输入必须明确拒绝，并且不得覆盖旧配置。

### 10.6 原子性

分别在以下阶段制造失败：

1. env 校验失败。
2. 文本渲染失败。
3. jq filter 失败。
4. JSON 格式检查失败。
5. 服务语义检查失败。
6. `config-all` 在服务端完成、客户端失败。

每次都比较修复前后所有正式输出的 SHA-256，并确认 `.render.*` 被清理。

## 11. 工作区说明

审查时以下文件未被提交跟踪：

```text
doc/config-rendering-unification-plan.md
fly-auto-changes.patch
```

执行修复的 agent 不得误删或覆盖这两个文件。是否把方案文档纳入版本控制，由维护者单独决定。

