# Hướng dẫn Setup & Update — Gesture trên server vật lý GPU

Quy trình:
chuẩn bị source/wheels/model → chạy setup offline → chạy foreground hoặc background
hoặc systemd. Mỗi lần cập nhật, dừng gesture, chạy lại cùng script setup rồi chạy lại.
`setup-gpu-server.sh` tự cài đặt, không gọi `install.sh`/`upgrade.sh` cũ.

## Thư mục và cấu hình đã thống nhất

| Thành phần | Giá trị |
| --- | --- |
| Server | Cùng server vật lý đang chạy Nemotron |
| SRC_DIR | `/u01/ims/namcht/gesture` |
| APP_DIR | `/u01/ims/mediapipe_gesture` |
| Venv mới | `/u01/ims/mediapipe_gesture/libs/venv` |
| Venv đã có | Giữ đường dẫn trong `APP_DIR/.app_venv` |
| Python mặc định | `python3.12` (package yêu cầu Python 3.11+) |
| Delegate config mới | `gpu` |
| gRPC | `127.0.0.1:50053` |
| Metrics HTTP | `:9102/metrics` |
| Unit / environment | `mediapipe-gesture.service` / `/etc/mediapipe-gesture/env` |


## A. Setup lần đầu

### A.1. Chuẩn bị wheels trên máy build

Dùng Linux, kiến trúc, Python/ABI và nền tảng tương thích server:

```bash
cd /path/to/gesture
python3.12 -m pip wheel . --wheel-dir wheels
python3.12 -m pip download 'setuptools>=65' wheel --dest wheels
```

Giữ dependencies trong `pyproject.toml`. Wheelhouse cần đủ runtime dependencies
và build tools. Setup cài toàn bộ wheels bằng
`--no-index --no-deps --no-build-isolation`, sau đó cài package từ APP_DIR bằng cùng
các flag này. Setup không resolve/download thêm từ internet; `pip check` báo các
dependency thiếu/xung đột.

### A.2. Chuyển source lên đúng server hiện có

Copy toàn bộ project vào `/u01/ims/namcht/gesture`. Không cần cài rsync trên server. Source cần:

```text
/u01/ims/namcht/gesture/
├── src/ (bao gồm proto/video.proto)
├── scripts/
├── assets/
├── etc/config.yaml
├── checkpoint/gesture_recognizer.task
├── wheels/*.whl
├── pyproject.toml
├── setup.py
├── MANIFEST.in
└── README.md
```

Không cần copy `.git/`, `.venv/`, `run/` và `.app_dir` từ máy dev. Setup bỏ qua
source `.app_dir`, dùng APP_DIR đã quy định hoặc `APP_DIR`/`--app-dir` truyền rõ.

### A.3. Kiểm tra server và model

```bash
cd /u01/ims/namcht/gesture
python3.12 --version
nvidia-smi --query-gpu=index,name,driver_version,memory.total --format=csv,noheader
command -v realpath flock
ls wheels/*.whl
ls -lh checkpoint/gesture_recognizer.task
```

Model được copy tự động khi setup lần đầu:

```bash
bash scripts/copy-models.sh --dry-run
bash scripts/copy-models.sh
# Hoặc --src /path/to/model-store, --src /path/to/custom.task
```

Model đã có trong APP_DIR được giữ nguyên. `--replace` chỉ dùng khi chủ động đổi
model và gesture đã dừng.

### A.4. Cài đặt môi trường bằng setup-gpu-server.sh

```bash
cd /u01/ims/namcht/gesture
bash scripts/setup-gpu-server.sh --dry-run
sudo bash scripts/setup-gpu-server.sh
```

Có thể chạy không sudo nếu tài khoản có quyền ghi APP_DIR và venv. Khi chạy bằng
sudo, thư mục APP_DIR, logs và run được cấp quyền ghi cho `SUDO_USER`, hoặc tài khoản
truyền bằng `--service-user`. Source, model và config phải đọc được bởi tài khoản đó.

Setup thực hiện:

1. Kiểm tra Python, NVIDIA và wheelhouse; yêu cầu gesture đã dừng.
2. Tạo hoặc dùng lại venv; chạy `ensurepip` nếu thiếu pip.
3. Deploy `src/`, `scripts/`, `assets/` và các file packaging sang APP_DIR.
   Có rsync thì dùng `rsync --delete` trong ba thư mục code này; thiếu thì dùng
   `cp -r`. Nhánh cp giữ các file đích đã bị xóa khỏi source.
4. Cài tất cả wheels offline, cài package **từ APP_DIR**, chạy `pip check`.
5. Tạo config lần đầu với model/log tuyệt đối, GPU, gRPC/metrics đã thống nhất;
   config/model cũ được giữ nguyên.
6. Validate imports/config, lưu `.app_venv`, tạo `APP_DIR/start.sh` và `stop.sh`.

Setup **không khởi tạo model thật**
và không khởi động service. Model GPU được khởi tạo khi chạy worker. Nếu cần probe
riêng trước khi chạy, dùng bước A.7.

Nếu đã có config CPU, setup sẽ cảnh báo nhưng giữ nguyên YAML. Sau khi dừng
gesture, backup config và đổi đúng `gesture.delegate` sang `gpu`:

```bash
cp /u01/ims/mediapipe_gesture/etc/config.yaml \
   /u01/ims/mediapipe_gesture/etc/config.yaml.before-gpu
vi /u01/ims/mediapipe_gesture/etc/config.yaml
```

`--delegate gpu` chỉ áp dụng cho config mới, không ghi đè config đang vận hành.

### A.5. Chạy trực tiếp bằng run-gpu-server.sh

Sau khi setup thành công, dùng tài khoản vận hành:

```bash
cd /u01/ims/namcht/gesture
bash scripts/run-gpu-server.sh
```

Hoặc chạy launcher đã deploy:

```bash
bash /u01/ims/mediapipe_gesture/scripts/run-gpu-server.sh
```

Hai lệnh cùng dùng config/model/venv tại APP_DIR, đổi working directory về APP_DIR
và exec worker foreground. Dừng bằng `Ctrl+C` hoặc SIGTERM. Log console hiện trên
terminal, JSON log ở `APP_DIR/logs/mediapipe-gesture.log`.

Chạy background:

```bash
bash /u01/ims/mediapipe_gesture/start.sh
tail -f /u01/ims/mediapipe_gesture/logs/console.log
# Dừng
bash /u01/ims/mediapipe_gesture/stop.sh
```

`start.sh` dùng nohup, lưu `APP_DIR/run.pid` và `run.start` để kiểm tra PID tái sử
dụng; `stop.sh` gửi SIGTERM và chờ tối đa 35 giây. Message Started chỉ xác nhận
process đã chạy, cần đợi `gesture server ready` trong log. `stop.sh` chỉ quản lý
process do `start.sh` tạo; foreground và systemd dừng bằng đúng cách tương ứng.
Launcher giữ lock suốt đời process để chặn chạy trùng hoặc setup khi đang chạy.

### A.6. Systemd tùy chọn

```bash
cd /u01/ims/namcht/gesture
sudo bash scripts/setup-gpu-server.sh --systemd
sudo systemctl start mediapipe-gesture
sudo systemctl status mediapipe-gesture --no-pager -l
journalctl -u mediapipe-gesture -f
```

Unit chạy launcher tại APP_DIR, `WorkingDirectory=APP_DIR`, `Restart=on-failure`,
đọc `/etc/mediapipe-gesture/env`. Setup chỉ install/enable, không tự start/restart.
Mặc định user là `SUDO_USER`; dùng `--service-user TEN_USER` nếu cần chỉ định tài
khoản vận hành hiện có. Không chạy đồng thời foreground, background và systemd.

### A.7. Kiểm tra GPU và readiness

MediaPipe GPU cần wheel hỗ trợ delegate và môi trường EGL/OpenGL ES tương ứng. Xem
[tài liệu GPU MediaPipe](https://developers.google.com/edge/mediapipe/framework/getting_started/gpu_support).
Không tự cài/thay driver hoặc EGL/display nếu chưa thống nhất với quản trị server.

Probe model thật khi gesture đã dừng, bằng đúng tài khoản/môi trường sẽ chạy nó:

```bash
bash /u01/ims/mediapipe_gesture/scripts/check-gpu-server.sh
```

Probe kiểm tra EGL/GLES và khởi tạo recognizer với delegate trong YAML; timeout
120 giây, lỗi trả exit khác 0, không tự fallback CPU. Probe không đo throughput
hoặc xác nhận toàn bộ operation đều dùng GPU. Khi đã thống nhất môi trường
EGL/display riêng, dùng cùng môi trường cho probe và service; không source file
systemd env như shell script. Không có GPU assignment mới được thêm trong script.

Sau start:

```bash
ss -ltnp | grep -E ':50053|:9102'
curl --fail http://127.0.0.1:9102/metrics
grep 'gesture server ready' /u01/ims/mediapipe_gesture/logs/mediapipe-gesture.log | tail
nvidia-smi
```

Kỳ vọng `gesture server ready addr=127.0.0.1:50053 delegate=gpu`. TCP/metrics xác
nhận listener; cần gửi JPEG qua RPC để kiểm chứng nhận diện thực tế.

## B. Cập nhật code/config/model

Đưa source mới vào `/u01/ims/namcht/gesture`, sau đó chạy lại **cùng script setup**.

Foreground: nhấn Ctrl+C ở terminal chạy worker rồi:

```bash
cd /u01/ims/namcht/gesture
sudo bash scripts/setup-gpu-server.sh
bash scripts/run-gpu-server.sh
```

Background:

```bash
bash /u01/ims/mediapipe_gesture/stop.sh
cd /u01/ims/namcht/gesture
sudo bash scripts/setup-gpu-server.sh
bash /u01/ims/mediapipe_gesture/start.sh
```

Systemd:

```bash
sudo systemctl stop mediapipe-gesture
cd /u01/ims/namcht/gesture
sudo bash scripts/setup-gpu-server.sh
sudo systemctl start mediapipe-gesture
```

Chỉ start khi setup thành công. Nếu đổi unit/user thì chạy setup với `--systemd`
và cùng `--service-user` đã chọn. Config/model/venv đã có được giữ nguyên, code và
scripts được cập nhật. Có downtime, không có rollback package tự động.

Đổi config: sửa `APP_DIR/etc/config.yaml`, restart theo cách đang dùng. Đổi model:
dừng gesture, backup model, dùng `copy-models.sh --src ... --replace`, probe và start.

Không dùng `install.sh`/`upgrade.sh` cũ để cập nhật deployment GPU này. Các script
cũ được giữ cho layout phát triển trước đây; khi APP_DIR có marker
`.gpu-server-deployment`, install/upgrade/start/stop/restart/status cũ sẽ báo dùng
setup và start/stop ở root APP_DIR. Chúng không thay đổi deployment GPU.
Nếu chuyển từ deployment cũ, dừng bằng supervisor/script cũ trước lần setup mới.

## C. Layout APP_DIR

```text
/u01/ims/mediapipe_gesture/
├── src/, scripts/, assets/           # deploy từ SRC_DIR
├── pyproject.toml, setup.py, MANIFEST.in, README.md
├── etc/config.yaml                  # chỉ tạo lần đầu
├── models/gesture_recognizer.task    # chỉ copy lần đầu
├── libs/venv/                       # hoặc .app_venv hiện có
├── logs/console.log                 # nohup của start.sh
│   └── mediapipe-gesture.log         # JSON, rotate theo cấu hình
├── run/gpu-server.lock              # lock dùng chung setup và worker
├── .app_venv
├── .gpu-server-deployment
├── start.sh, stop.sh
└── run.pid, run.start               # chỉ khi chạy background bằng start.sh
```

## D. Kiểm thử và lỗi thường gặp

```bash
python3.12 tests/test_gpu_deployment.py -v
```

Tests dùng thư mục tạm, pip/NVIDIA/MediaPipe giả lập: kiểm tra cài offline theo
Nemotron, ensurepip, fallback cp, bảo toàn config/model, setup độc lập với installer
cũ, lock foreground, migration process cũ và start/stop bằng PID thật không cần TCP.
Chưa thay thế cho xác minh GPU/nhận diện thật trên server đích.

| Lỗi | Xử lý |
| --- | --- |
| No wheels / pip check failed | Bổ sung wheelhouse đúng Python/ABI/OS và dependency; không đổi dependency tùy ý. |
| Gesture is running / setup active | Dừng đúng instance trước setup; không xóa lock/PID để bỏ qua kiểm tra. |
| EGL/GLES/GPU delegate failed | Kiểm tra wheel và môi trường GPU với quản trị viên; không tự đổi CPU/driver. |
| Existing YAML uses CPU | Backup và sửa gesture.delegate sang gpu, probe lại. |
| Port occupied | Xác định process giữ cổng; không tự đổi cổng hoặc kill process khác. |
| Missing run.start / shutdown timeout | Kiểm tra metadata/process; stop giữ metadata và không SIGKILL tự động. |
