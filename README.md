# 115nas — 115 生活客户端 Docker 版

全AI生成，把 **115 生活官方 Linux 桌面客户端**（`115Life_37.3.1.deb`）跑进 Docker 容器，  
通过浏览器（noVNC）直接使用：**扫码登录、文件浏览/管理、上传、下载、云下载、  
在线播放、分享**，官方客户端全功能保留，减少风控危险，无需在电脑上装任何软件。

- 一条 `docker compose up -d` 完成部署（首次构建约 5-15 分钟）
- 浏览器打开 `http://<主机IP>:6080/` 即用，自动进入客户端
- 扫码登录态持久化：重建容器不丢登录
- **内置 fcitx5 拼音输入法**：noVNC 窗口内 `Ctrl+Space` 直接打中文
- NAS 共享目录挂进容器，下载直接落盘；也可 `docker save` 导出镜像免重复构建
- 任意 Docker 主机可用：Linux / 群晖 DSM / QNAP Container Station / Windows

## 快速开始

```bash
# 1. 构建并启动（NAS_SHARE 指向宿主机上的目录，客户端下载落地处）
NAS_SHARE=/share/Download docker compose up -d

# 2. 打开浏览器
http://<主机IP>:6080/
```

首次会构建镜像（拉 debian:12 + apt + 官方 deb，约 5-15 分钟）。  
之后用 115 App 扫码登录。

不用 compose 的话，等价 `docker run`：

```bash
docker build -t 115nas:1.1.0 .

docker run -d --name 115nas --restart unless-stopped --shm-size=1g \
  -p 6080:6080 -p 6081:6081 \
  -e TZ=Asia/Shanghai \
  -v ./data/config:/config -v ./data/appdata:/appdata \
  -v ./data/cache:/cache -v ./logs:/logs \
  -v /share/Download:/media/nas -v /share/Download:/root/Downloads \
  115nas:1.1.0
```

## 中文输入

容器内已装 **fcitx5 拼音**：

1. 在 noVNC 窗口里点一下输入框
2. 按 `Ctrl+Space` 呼出输入法
3. 打拼音，候选项显示在虚拟屏上，**数字键选字**

任何场景都可以用「电脑上复制 → noVNC 窗口内 `Ctrl+V` 粘贴」兜底  
（noVNC 不传输本机输入法，但剪贴板是通的）。

## 目录与持久化

| 容器内路径               | 宿主机（compose 默认）  | 说明                                |
| ------------------- | ---------------- | --------------------------------- |
| `/root/Downloads`   | `$NAS_SHARE`     | **客户端默认下载目录**，直接落宿主机磁盘            |
| `/media/nas`        | `$NAS_SHARE`     | 同一目录的另一个入口，客户端文件选择器可见             |
| `/config`           | `./data/config`  | 客户端配置（勿删）                         |
| `/appdata`          | `./data/appdata` | WebKit Cookie = **扫码登录态**（勿删）     |
| `/cache`            | `./data/cache`   | 视频缓存（可清理）                         |
| `/logs`             | `./logs`         | 各组件日志                             |
| `/certs/server.pem` | 挂载点              | HTTPS 证书（ PEM，证书+私钥合一）；存在才监听 6081 |

## 配置（环境变量）

| 变量                                                | 默认                  | 说明                              |
| ------------------------------------------------- | ------------------- | ------------------------------- |
| `TZ`                                              | `Asia/Shanghai`     | 时区                              |
| `SCREEN_WIDTH` / `SCREEN_HEIGHT` / `SCREEN_DEPTH` | 1280 / 800 / 24     | 虚拟屏分辨率（浏览器端自动缩放适配）              |
| `HTTP_PORT` / `HTTPS_PORT`                        | 6080 / 6081         | noVNC 端口（改需同步改 compose 的 ports） |
| `VNC_PASSWORD`                                    | 空                   | noVNC 连接密码。**暴露到公网时务必设置**       |
| `VNC_PORT`                                        | 5900                | x11vnc 端口（仅监听 127.0.0.1，一般不用改）  |
| `HTTPS_CERT`                                      | `/certs/server.pem` | HTTPS 证书路径                      |

## 镜像仓库（ghcr.io / Docker Hub）与自动更新

**115 官方客户端更新后，`latest` 标签自动跟进**（无需人工干预）：

- CI 每天 18:00（北京时间）查询 115 官方版本接口
  `https://appversion.115.com/1/web/1.0/api/getMultiVer` 的 `115Life_Linux` 项
- 发现新版本 → 自动下载 deb（校验 `dpkg Version` 与文件大小）→ 更新 Dockerfile
  并提交到 main → 同一流水线内重建镜像 → 推送 `latest`（同时更新 `main`/`edge`）
- NAS 上跟更新只需：`docker compose pull && docker compose up -d`
  （compose 默认引用 `:latest`；想锁定版本就改成具体 tag）
- 手动立即重建：Actions → Publish Docker image → Run workflow

打版本标签则发布固定版本（版本号 + `latest`）：

```bash
git tag v1.1.0 && git push origin v1.1.0
```

产物：`ghcr.io/xheia/115nas-docker:1.1.0`（ghcr 已发布 `main` / `edge`，public）；
配好 Docker Hub Secrets 后同时推 `xheia/115nas-docker:1.1.0`。

> Docker Hub 启用（一次性）：仓库 Settings → Secrets and variables → Actions 添加
> `DOCKERHUB_USERNAME`（Docker Hub 用户名）和 `DOCKERHUB_TOKEN`
> （hub.docker.com → Account Settings → Personal access tokens，权限 Read/Write/Delete，
> **不是登录密码**）。仓库不存在时首次推送自动创建，默认 private，推完可在 Hub 后台改
> public。ghcr.io 无需任何配置。

使用发布版镜像（跳过本地构建）：把 compose 里的 `build: .` 删掉，`image:` 改为

```yaml
image: ghcr.io/xheia/115nas-docker:latest
```

> 国内网络拉取 ghcr.io / docker.io 常需镜像加速或代理；拉不动就本地构建。
> 镜像内 115 客户端版本可用 `docker inspect --format '{{index .Config.Labels "115nas.client-version"}}' <镜像名>` 查看。

### CI 流水线完整配置

即 `.github/workflows/docker-publish.yml` 原文（仓库里改这里即可调整自动化行为）：

<details>
<summary>展开 docker-publish.yml（约 200 行）</summary>

```yaml
name: Publish Docker image

# 触发方式：
#   1) 定时（每天 18:00 北京时间）：检查 115 官方 Linux 客户端是否有新版本，
#      有则自动下载新 deb、更新 Dockerfile 并提交，然后重建发布 latest。
#   2) 打版本标签推送：git tag v1.1.0 && git push origin v1.1.0
#   3. GitHub 仓库页面手动：Actions → Publish Docker image → Run workflow
#
# 产物（均为 linux/amd64——官方 deb 只有 amd64，无法构建 ARM 镜像）：
#   定时/手动触发：ghcr.io/xheia/115nas-docker:{main,edge,latest}
#                 （配了 Docker Hub 密钥则同步推 <DOCKERHUB_USERNAME>/115nas-docker）
#   标签推送 v*  ：ghcr.io/xheia/115nas-docker:<version> + :latest
#
# 上游版本检测源（115 官方接口，免登录，实测海外 runner 可达 ~1s）：
#   https://appversion.115.com/1/web/1.0/api/getMultiVer
#   → data.115Life_Linux.version_code / .version_url
#   （该地址来自官方 deb 内 Core115.Net.dll 的字符串，非第三方推测）
#
# 需要的仓库 Secrets（Settings → Secrets and variables → Actions，均可选）：
#   DOCKERHUB_USERNAME  Docker Hub 用户名
#   DOCKERHUB_TOKEN     Docker Hub PAT，Read/Write/Delete（不是登录密码）
#   GHCR_PAT            带 write:packages 的 PAT，用于自动设 ghcr 包 public
#                       （GITHUB_TOKEN 调 /user/packages 会 404，管不了用户级包）
#
# 注意：secrets 上下文不能出现在 steps.if 里（GitHub 限制），
# 故先注入 job 级 env.DH_USER/DH_TOKEN，再用 env 上下文做条件判断。

on:
  push:
    tags: ["v*"]
  schedule:
    - cron: "0 10 * * *"   # 每天 18:00（UTC+8）
  workflow_dispatch:

env:
  IMAGE_NAME: 115nas-docker

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: write      # 定时任务要提交新 deb
      packages: write      # 推 ghcr
    env:
      DH_USER: ${{ secrets.DOCKERHUB_USERNAME }}
      DH_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
    steps:
      - uses: actions/checkout@v4

      # ---- 检查 115 官方更新（仅定时/手动触发时执行；打 tag 发版不查）----
      - name: Check 115 upstream update
        id: check
        if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
        run: |
          set -euo pipefail
          curl -sS -m 30 "https://appversion.115.com/1/web/1.0/api/getMultiVer" -o /tmp/mv.json
          python3 - <<'PYEOF'
          import json, re, os
          d = json.load(open('/tmp/mv.json'))
          entry = d['data']['115Life_Linux']
          up, url = entry['version_code'], entry['version_url']
          notice = entry.get('version_notice_url', '')
          df = open('Dockerfile', encoding='utf-8').read()
          m = re.search(r'^ARG LIFE_DEB=115Life_([0-9.]+)\.deb', df, re.M)
          if not m:
              raise SystemExit('Dockerfile 中找不到 ARG LIFE_DEB=115Life_<ver>.deb')
          cur = m.group(1)
          tup = lambda s: tuple(int(x) for x in s.split('.'))
          changed = tup(up) > tup(cur)
          with open(os.environ['GITHUB_OUTPUT'], 'a') as f:
              f.write(f'upstream={up}\ncurrent={cur}\nurl={url}\nnotice={notice}\n')
              f.write(f'changed={"true" if changed else "false"}\n')
          print(f'upstream={up}  current={cur}  changed={changed}')
          PYEOF

      # ---- 有新版本：下载、校验、替换 deb、更新 Dockerfile/README、提交 ----
      - name: Download and commit new deb
        if: steps.check.outputs.changed == 'true'
        run: |
          set -euo pipefail
          UP="${{ steps.check.outputs.upstream }}"
          CUR="${{ steps.check.outputs.current }}"
          URL="${{ steps.check.outputs.url }}"
          NOTICE="${{ steps.check.outputs.notice }}"
          echo "downloading $URL"
          curl -fSL --retry 3 --retry-delay 5 -m 900 -o "115Life_${UP}.deb" "$URL"
          V=$(dpkg-deb --field "115Life_${UP}.deb" Version)
          if [ "$V" != "$UP" ]; then
            echo "::error::deb Version ($V) 与上游版本 ($UP) 不一致，放弃提交"; exit 1
          fi
          SZ=$(stat -c%s "115Life_${UP}.deb")
          if [ "$SZ" -lt 50000000 ]; then
            echo "::error::deb 大小异常 (${SZ}B)，放弃提交"; exit 1
          fi
          rm -f "115Life_${CUR}.deb"
          sed -i "s/^ARG LIFE_DEB=115Life_[0-9.]*\.deb/ARG LIFE_DEB=115Life_${UP}.deb/" Dockerfile
          if grep -q "115Life_${CUR}\.deb" README.md; then
            sed -i "s/115Life_${CUR}\.deb/115Life_${UP}.deb/g" README.md
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add -A
          if git diff --cached --quiet; then
            echo "没有实际变更，跳过提交"
          else
            MSG="chore: bump 115Life ${CUR} -> ${UP}"
            if [ -n "$NOTICE" ]; then MSG="$MSG

          release notice: ${NOTICE}"; fi
            git commit -m "$MSG"
            git push origin HEAD:main || {
              echo "::warning::push 失败（可能有并发提交），rebase 后重试"
              git fetch origin main && git rebase origin/main && git push origin HEAD:main
            }
          fi

      # ---- 客户端版本号（写进镜像 label，docker inspect 可见）----
      - name: Read client version
        id: ver
        run: |
          CV=$(sed -n 's/^ARG LIFE_DEB=115Life_\([0-9.]*\)\.deb.*/\1/p' Dockerfile)
          echo "client_version=$CV" >> "$GITHUB_OUTPUT"
          echo "client version: $CV"

      # ---- ghcr.io（自动使用 GITHUB_TOKEN）----
      - name: Log in to ghcr.io
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      # ---- Docker Hub（未配置密钥则整步跳过，只发布 ghcr）----
      - name: Log in to Docker Hub
        if: ${{ env.DH_USER != '' && env.DH_TOKEN != '' }}
        uses: docker/login-action@v3
        with:
          username: ${{ env.DH_USER }}
          password: ${{ env.DH_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      # ---- 计算镜像标签 ----
      # 标签推送 v1.2.3 → 1.2.3 + latest；定时/手动（分支）→ main + edge + latest
      - name: Compute image tags
        id: tags
        run: |
          REF="${{ github.ref_name }}"
          VER="${REF#v}"
          GHCR="ghcr.io/${{ github.repository_owner }}/$IMAGE_NAME"
          if [ "${REF#v}" != "$REF" ]; then
            TAGS="${GHCR}:${VER},${GHCR}:latest"
          else
            TAGS="${GHCR}:main,${GHCR}:edge,${GHCR}:latest"
          fi
          if [ -n "$DH_USER" ]; then
            if [ "${REF#v}" != "$REF" ]; then
              TAGS="${TAGS},${DH_USER}/$IMAGE_NAME:${VER},${DH_USER}/$IMAGE_NAME:latest"
            else
              TAGS="${TAGS},${DH_USER}/$IMAGE_NAME:main,${DH_USER}/$IMAGE_NAME:edge,${DH_USER}/$IMAGE_NAME:latest"
            fi
          fi
          echo "tags=$TAGS" >> "$GITHUB_OUTPUT"
          echo "将推送: $TAGS"

      # ---- 构建并推送（amd64）----
      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
          tags: ${{ steps.tags.outputs.tags }}
          build-args: |
            CLIENT_VERSION=${{ steps.ver.outputs.client_version }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      # ---- ghcr 包默认 private，尝试改成 public（失败不阻断）----
      # 根因（2026-10-18 实测）：GITHUB_TOKEN 是 installation token，PATCH
      # /user/packages/... 对它返回 404 Not Found——它无法管理用户级包。
      # 两条路：① 手动改一次（visibility 是持久属性，之后永久保持）；
      # ② 想要全自动：建一个带 write:packages 权限的 PAT，
      # 存为仓库 Secret GHCR_PAT，本步会优先使用它。
      - name: Make ghcr package public (best effort)
        continue-on-error: true
        env:
          CR_PAT: ${{ secrets.GHCR_PAT }}
        run: |
          TOKEN="${{ secrets.GITHUB_TOKEN }}"
          if [ -n "$CR_PAT" ]; then TOKEN="$CR_PAT"; fi
          RESP=$(curl -sS -X PATCH \
            -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -w "\n%{http_code}" \
            "https://api.github.com/user/packages/container/115nas-docker" \
            -d '{"visibility":"public"}')
          echo "response: $RESP"
          case "$RESP" in
            *200|*201) echo "ghcr 包已设为 public" ;;
            *) echo "自动设置公开失败——visibility 是持久属性，手动改一次即可：Package settings -> Change visibility -> Public" ;;
          esac
```

</details>

## 排障

| 现象               | 排查                                                            |
| ---------------- | ------------------------------------------------------------- |
| 打开 6080 显示「拒绝连接」 | 容器没起来：`docker ps -a` 看状态；`docker logs 115nas` 看原因；首次启动后镜像还在构建 |
| 界面一直转圈连不上        | 看容器内 `/logs/entrypoint.log`、`x11vnc.log`、`websockify.log`     |
| 扫码后重启要重新扫码       | `/config`、`/appdata` 没挂卷或被删                                   |
| 下载的文件不在 NAS 上    | 下载目录被改过——客户端设置里指回 `/root/Downloads`；或检查 `NAS_SHARE` 挂载        |
| 中文输不进去           | `Ctrl+Space` 呼出 fcitx5；不行就用 `Ctrl+V` 粘贴                       |
| 端口 6080 被占用      | 改 `HTTP_PORT` 并同步 compose 的 ports 映射                          |
| 想重新构建镜像          | `docker compose build --no-cache`                             |

## 已知限制

- 视频播放为软件解码（无 GPU 直通），高码率片源可能卡顿
- 官方客户端仅 amd64/x86_64，ARM 主机无法运行（deb 依赖决定）
- 单容器单 115 账号（多开：复制一份 compose，改容器名与端口）
- noVNC 不传输本机输入法——中文靠容器内 fcitx5 或粘贴

## 目录结构

```
Dockerfile          镜像定义（debian:12 + X 栈 + fcitx5 + 官方 deb）
entrypoint.sh       容器入口：dbus→Xvfb→openbox→fcitx5→x11vnc→websockify→Life115
docker-compose.yml  Compose 编排
115Life_37.3.1.deb  115 生活官方 Linux 客户端（随仓库分发，构建时 COPY 进镜像）
.github/workflows/  CI：每天检查 115 官方更新自动重建 latest；打版本标签发布
```

## 版权与许可

- 本项目代码（Dockerfile / entrypoint.sh / compose）：MIT
- `115Life_37.3.1.deb` 版权归 **广东一一五科技股份有限公司** 所有，  
  本仓库仅打包其官方 deb 以便离线构建，不修改其内容
