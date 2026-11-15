# KiCad Library — Kien Hoang

Thư viện KiCad tổng hợp và chuẩn hóa do **Hoàng Lê Trung Kiên** xây dựng, bao gồm Symbols, Footprints, 3D Models và cơ sở dữ liệu linh kiện.

## Nội dung thư viện

| Thành phần | Số lượng |
|---|---:|
| Symbol | 121 thư viện |
| Footprint | 1.852 tệp |
| 3D Models | 637 tệp STEP/WRL |
| Linh kiện trong database | 3.573 |
| Hãng sản xuất | 243 |
| Cấu hình thư viện | 6 profiles |

## Cấu trúc chính

- `Official/` — Dữ liệu KiCad gốc.
- `Libraries/` — Symbols, Footprints và 3D Models.
- `Templates/` — Template schematic và PCB.
- `Database/` — Cơ sở dữ liệu linh kiện CSV và SQLite.
- `Tools/` — Công cụ cài đặt, chuẩn hóa và kiểm tra.
- `SETUP_KICAD.cmd` — Bộ cài đặt tự động.
- `README.md` — Hướng dẫn sử dụng.

## Cài đặt

1. Đóng KiCad.
2. Chạy `SETUP_KICAD.cmd`.
3. Chọn một trong các chế độ:
   - **FULL:** Cài đặt toàn bộ thư viện.
   - **CUSTOM:** Chỉ sử dụng thư viện tùy chỉnh.
   - **DRY RUN:** Kiểm tra mà không thay đổi cấu hình.
   - **ROLLBACK:** Khôi phục cấu hình trước đó.

Công cụ tự động phát hiện phiên bản KiCad, cấu hình đường dẫn, sao lưu dữ liệu và giữ nguyên các thư viện người dùng đã cài đặt.

## Kiểm chứng

Chạy lệnh:

```bash
python Tools/python/validate_library.py
```

Kết quả kiểm tra hiện tại:

```text
symbol_parse_failures      0
footprint_parse_failures   0
footprint_refs             3738
model_refs                  302
symbol_dup_files             0
```

**Mục tiêu:** Xây dựng một hệ sinh thái thư viện KiCad tập trung, nhất quán, dễ triển khai và có thể sử dụng trên nhiều máy tính.

---

**Copyright © Hoang Le Trung Kien.**
