# Thư viện KiCad — KiCad Library Kien Hoang

Bộ thư viện KiCad chuẩn hoá tổng hợp đầy đủ linh kiện (Symbols, Footprints, 3D Models)
được thiết kế bởi Hoàng Lê Trung Kiên (Copyright by Hoang Le Trung Kien).

Mọi thành phần đều đã được kiểm chứng bằng chính bộ phân tích của KiCad 10:
symbol và footprint nạp không lỗi, liên kết symbol → footprint và footprint → 3D model
đều trỏ tới tệp có thật trên đĩa.

---

## 📊 Nội dung thư viện

| Thành phần | Số lượng | Ghi chú |
|---|---:|---|
| Thư viện symbol | 121 `.kicad_sym` | Antmicro (nguồn hardware-components) + Personal |
| Tệp footprint | 1.852 `.kicad_mod` | 1.583 trong *Hardware Components Footprints*, còn lại ở 100 thư viện Personal |
| Mô hình 3D | 637 tệp STEP/WRL | riêng `Libraries/3D_Models/Personal` ≈ 1,5 GB |
| Bảng thư viện | 6 profile | FULL / CUSTOM_ONLY / PROJECT_SPECIFIC cho cả sym và fp |
| Cơ sở dữ liệu | 3.573 linh kiện | 243 hãng sản xuất, tra cứu bằng CSV hoặc SQLite |

Kết quả kiểm tra hiện tại:

```text
symbol_parse_failures      0
footprint_parse_failures   0
footprint_refs             3738   (0 lỗi)
model_refs                  302   (0 lỗi)
symbol_dup_files             0
```

---

## 📁 Cấu trúc thư mục

```text
Kicad_Library_KienHoang/
├── Official/            # Dữ liệu nguồn KiCad chính thức (symbols, footprints, 3D, templates)
├── Libraries/           # Thư viện tổng hợp
│   ├── Symbols/         # Toàn bộ symbols (gốc + Personal/)
│   ├── Footprints/      # Toàn bộ footprints (*.pretty)
│   ├── 3D_Models/       # Toàn bộ model 3D (Personal/3D/...)
│   └── Tables/          # sym-lib-table & fp-lib-table theo từng profile
├── Templates/           # Khung tên Layout.kicad_wks & design blocks
├── Database/            # CSDL tra cứu linh kiện (CSV + SQLite) và báo cáo kiểm tra
├── Tools/
│   ├── powershell/      # Bộ cài đặt, gỡ cài đặt, kiểm tra bảng thư viện
│   └── python/          # Công cụ chuẩn hoá và kiểm chứng thư viện
├── SETUP_KICAD.cmd      # Bộ cài đặt tự động cho Windows
└── README.md            # Hướng dẫn sử dụng (tiếng Việt)
```

---

## 🚀 Cài đặt

Dùng được cho máy hiện tại hoặc sau khi copy thư mục sang bất kỳ ổ đĩa/máy nào
(`C:`, `D:`, `E:` …) — mọi đường dẫn trong bảng thư viện đều tương đối với gốc repo.

1. **Đóng KiCad** (nếu đang mở).
2. Chạy **`SETUP_KICAD.cmd`**.
3. Chọn:

   | Phím | Chế độ | Kết quả |
   |---|---|---|
   | `1` | **FULL** | Toàn bộ thư viện chính thức + phần tuỳ chỉnh (344 symbol lib, 256 footprint lib) |
   | `2` | **CUSTOM** | Chỉ phần tuỳ chỉnh và cá nhân — KiCad khởi động nhanh nhất (121 / 101) |
   | `3` | **DRY RUN** | Chạy thử, chỉ báo cáo, **không** ghi gì |
   | `4` | **ROLLBACK** | Khôi phục một lần cài trước đó |
   | `5` | Thoát | |

4. Script tự động:
   * Dò phiên bản KiCad đang cài và thư mục cấu hình tương ứng.
   * Gộp bảng thư viện, **giữ nguyên** các thư viện người dùng đã tự thêm.
   * Đăng ký biến đường dẫn `${KICAD_ECO_ROOT}` và `${KICAD_LIBRARY}`.
     `KICAD_LIBRARY` được phát hiện từ chính nội dung các footprint, vì đường dẫn
     3D model nằm trong tệp `.kicad_mod` chứ không nằm trong bảng thư viện.
   * Sao lưu mọi tệp trước khi sửa, ghi theo kiểu nguyên tử (atomic write).
   * Cài khung tên và design block nếu máy chưa có.
5. Mở lại KiCad và dùng ngay.

### Nơi lưu bản sao lưu

```text
%LOCALAPPDATA%\KiCad Library Kien Hoang\Backups\
```

Mỗi bản sao lưu có mã thời gian `YYYYMMDD-HHMMSS`; nhập mã đó vào mục **ROLLBACK**
để quay lại đúng trạng thái cũ.

---

## 🧰 Công cụ dòng lệnh

| Tệp | Chức năng |
|---|---|
| `Tools/powershell/setup_kicad_ecosystem.ps1` | Bộ cài chính (menu `SETUP_KICAD.cmd` gọi tệp này) |
| `Tools/powershell/install_library_tables.ps1` | Chỉ cài bảng thư viện, có `-DryRun`, `-Merge` |
| `Tools/powershell/uninstall_library_tables.ps1` | Gỡ phần thư viện do repo này thêm vào |
| `Tools/python/validate_library.py` | Kiểm tra toàn bộ thư viện, **chỉ đọc**, exit code 0 = sạch |
| `Tools/python/finalize_library.py` | Chuẩn hoá `Footprint` của symbol và block `(model …)` (idempotent) |
| `Tools/python/legacy/` | Script cũ, đã lưu trữ — chỉ để tham khảo |

Ví dụ:

```powershell
# Chạy thử, không thay đổi gì
powershell -ExecutionPolicy Bypass -File Tools\powershell\setup_kicad_ecosystem.ps1 -Profile FULL -DryRun

# Cài bảng thư viện kiểu gộp (giữ entry của người dùng)
powershell -ExecutionPolicy Bypass -File Tools\powershell\install_library_tables.ps1 -Profile CUSTOM_ONLY -Merge

# Gỡ cài đặt
powershell -ExecutionPolicy Bypass -File Tools\powershell\uninstall_library_tables.ps1 -Timestamp 20261112-002214
```

```bash
python Tools/python/validate_library.py          # audit
python Tools/python/finalize_library.py          # dry run
python Tools/python/finalize_library.py --apply  # ghi thay đổi
```

---

## 🗄️ Cơ sở dữ liệu linh kiện

| Tệp | Nội dung |
|---|---|
| `Database/component_master.csv` | 3.573 linh kiện, 26 cột: hãng, MPN, category, symbol, footprint, datasheet, cờ `*_present`, `quality_flags` |
| `Database/component_master.sqlite` | Cùng dữ liệu dạng SQLite (bảng `components`) |
| `Database/personal_library.sqlite` | Danh mục 487 linh kiện của thư viện cá nhân |
| `Database/component_db_summary.json` | Thống kê tổng hợp theo category và quality flag |
| `Database/finalize-report-*.csv` | Nhật ký từng thay đổi do `finalize_library.py` tạo ra |

Cột `symbol_present` / `footprint_present` / `model_present` đã được đối chiếu với
đĩa. Hiện còn 11 tài nguyên thiếu, đều đã đánh dấu `MISSING_ASSET` — tra bằng:

```bash
grep MISSING_ASSET Database/component_master.csv
```

---

## ✅ Kiểm chứng trước khi commit

```bash
python Tools/python/validate_library.py
```

Script chạy `kicad-cli` thật để nạp từng thư viện, sau đó kiểm tra: liên kết
symbol → footprint, đường dẫn 3D model, trùng tên trong bảng, và symbol trùng
trong cùng một tệp. Exit code `0` nghĩa là thư viện sạch.

---

## 📝 Quy ước biến đường dẫn

| Biến | Trỏ tới |
|---|---|
| `${KICAD_ECO_ROOT}` | Gốc repo (dùng cho thư viện Personal / Hardware Components) |
| `${KICAD_LIBRARY}` | `Libraries/3D_Models/Personal` — gốc của mọi đường dẫn 3D model trong footprint |
| `${KICAD10_SYMBOL_DIR}` … | Thư mục cài đặt của KiCad (do KiCad tự định nghĩa) |
| `${KIPRJMOD}` | Chỉ dùng trong profile `PROJECT_SPECIFIC` |

---

## 🔐 Bản quyền

Copyright by Hoang Le Trung Kien.

Dữ liệu trong `Official/` thuộc về dự án KiCad và giữ nguyên giấy phép gốc.
Dữ liệu Antmicro giữ giấy phép Apache-2.0 của dự án `antmicro/hardware-components`.
