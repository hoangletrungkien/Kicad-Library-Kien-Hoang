# KiCad Library — Kien Hoang

Thư viện KiCad tổng hợp và chuẩn hóa do **Hoàng Lê Trung Kiên** phát triển, cung cấp hệ sinh thái linh kiện điện tử bao gồm Symbols, Footprints, 3D Models và cơ sở dữ liệu linh kiện.

## Tổng quan

| Thành phần | Số lượng |
|:---|---:|
| Symbol Libraries | 121 thư viện |
| Footprint Files | 1.852 tệp |
| 3D Models | 637 tệp STEP/WRL |
| Components Database | 3.573 linh kiện |
| Manufacturers | 243 hãng |
| Library Profiles | 6 profiles |

## Cấu trúc thư mục

```text
KiCad_Library_KienHoang/
│
├── Official/                       # Dữ liệu thư viện KiCad gốc
│
├── Libraries/
│   ├── Symbols/                    # Symbol libraries
│   ├── Footprints/                 # Footprint libraries
│   └── 3D_Models/                  # STEP and WRL models
│
├── Templates/                      # Schematic and PCB templates
│
├── Database/                       # Component database (CSV / SQLite)
│
├── Tools/
│   ├── powershell/                 # Installation and automation tools
│   └── python/                     # Validation and library utilities
│
├── SETUP_KICAD.cmd                 # Automated setup utility
│
└── README.md                       # Project documentation
```

## Yêu cầu hệ thống

| Thành phần | Yêu cầu |
|:---|:---|
| Operating System | Windows 10 / 11 |
| KiCad | Version 7.x – 10.x |
| PowerShell | Windows PowerShell |
| Python | Chỉ cần khi sử dụng các công cụ Python |

## Cài đặt

### 1. Chuẩn bị

- Giải nén thư viện vào thư mục mong muốn.
- Đóng tất cả ứng dụng KiCad đang chạy.
- Đảm bảo cấu trúc thư mục không bị thay đổi.

### 2. Khởi chạy

Chạy tệp `SETUP_KICAD.cmd` bằng quyền người dùng thông thường.

### 3. Chọn chế độ cài đặt

| Lựa chọn | Chế độ | Chức năng |
|:---:|:---|:---|
| 1 | **FULL SETUP** | Tích hợp toàn bộ thư viện và tối ưu hiệu năng KiCad. |
| 2 | **CUSTOM SETUP** | Tích hợp thư viện bổ sung, thư viện cá nhân và tối ưu hiệu năng. |
| 3 | **MAINTENANCE** | Truy cập các công cụ bảo trì và khôi phục hệ thống. |


## Copyright

**KiCad Library — Kien Hoang**

Developed and maintained by **Hoang Le Trung Kien**.

Copyright © Hoang Le Trung Kien. All rights reserved.
