# Thư viện KiCad — KiCad Library Kien Hoang

Bộ thư viện KiCad chuẩn hóa tổng hợp đầy đủ linh kiện (Symbols, Footprints, 3D Models) đ
ợc thiết kế bởi Hoàng Lê Trung Kiên (Copyright by Hoang Le Trung Kien)---

## 📁 Cấu trúc Thư mục

```text
Kicad_Library_KienHoang/
├── Official/           # Dữ liệu nguồn KiCad chính thức
├── Libraries/          # Thư viện tổng hợp 
│   ├── Symbols/        # Toàn bộ Symbols 
│   ├── Footprints/     # Toàn bộ Footprints 
│   ├── 3D_Models/      # Toàn bộ Models 3D 
│   └── Tables/         # Bảng thư viện sym-lib-table & fp-lib-table 
├── Templates/          # Khung tên bản vẽ Layout.kicad_wks & Design Blocks
├── Database/           # Cơ sở dữ liệu tra cứu linh kiện (SQLite, CSV)
├── Tools/              # Script
├── SETUP_KICAD.cmd     # File Setup
└── README.md           # Hướng dẫn sử dụng tiếng Việt
```

---

## 🚀 Hướng dẫn Cài đặt & Sử dụng

Dùng cho máy tính hiện tại hoặc copy thư mục sang bất kỳ máy tính/ổ đĩa nào khác (`C:`, `D:`, `E:`):

1. **Đóng KiCad** (nếu đang mở).
2. Chạy tệp: **`SETUP_KICAD.cmd`**
3. Nhập phím **`1`** (hoặc nhấn Enter) để chọn chế độ **FULL**.
4. Script sẽ tự động:
   * Tìm vị trí cài đặt KiCad trên máy.
   * Apply toàn bộ vào KiCad.
   * Cấu hình biến môi trường `${KICAD_ECO_ROOT}` và `${KICAD_LIBRARY}` để load đúng 3D Models.
5. **Mở KiCad** và sử dụng ngay lập tức!

---
