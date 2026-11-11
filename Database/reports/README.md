# Báo cáo chuẩn hoá thư viện

Nhật ký các lần chuẩn hoá thư viện, dùng để tra lại *vì sao* một giá trị đã thay đổi.
Không cần cho việc dùng thư viện hằng ngày; có thể xoá an toàn.

| Tệp | Sinh ra bởi | Nội dung |
|---|---|---|
| `finalize-report-*.csv` | `Tools/python/finalize_library.py` | Từng thay đổi `Footprint` của symbol và block `(model …)`, kèm cột `status` (`FIXED_DB`, `UNWRAPPED`, `TEMPLATE_CLEARED`, `RELINKED`, `REMOVED`, …) |
| `footprint_repair_report-*.csv` | `Tools/python/legacy/repair_footprints.py` | Lần sửa Antmicro đầu tiên (đã lưu trữ) |

Cột `status` trong báo cáo `finalize`:

| Status | Ý nghĩa |
|---|---|
| `FIXED_DB` | Giá trị lấy từ `Database/component_master.csv` |
| `FIXED_MANUAL` | Ánh xạ thủ công đã kiểm chứng số pin/pad |
| `UNWRAPPED` | Bỏ phần `Lib:['X']` của upstream, giữ lại `X` |
| `TEMPLATE_CLEARED` | Symbol mẫu (`*_template_*`) — xoá placeholder |
| `CLEARED_NO_FOOTPRINT` | Không tìm được footprint nào → để trống thay vì trỏ hỏng |
| `RELINKED` | Block `(model …)` trỏ lại tệp 3D có thật |
| `REMOVED` | Block `(model …)` rỗng hoặc vô nghĩa đã bị xoá |
| `unchanged` | Không cần sửa |
