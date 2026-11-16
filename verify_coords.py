#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""坐标一致性校验：验证「坐标悬浮窗显示的坐标」== 「采集器 mouse_click 实际点击的位置」

用法：
    python verify_coords.py            # 用当前鼠标位置 + 屏幕内多点复测
    python verify_coords.py 960 540    # 指定坐标（额外再测该点）

做的事（每个测试点）：
    1. 开启 DPI 感知（与采集器一致）
    2. 调采集器真实的 computer.mouse_click(x, y)
    3. 用 GetCursorPos 读回落点，与目标比对
    4. 多点复测，给出最大偏差与结论

为什么要验：
    Windows 在 125% / 150% 缩放下，未声明 DPI 感知的进程拿到「逻辑像素」，
    与点位表里的「物理像素」差 1.25 / 1.5 倍——肉眼看不出来，点位会系统性偏移。
"""
import ctypes
import os
import sys
import time

# ---------------- DPI 感知（与采集器一致） ----------------
try:
    ctypes.WinDLL("user32").SetProcessDPIAware()
    DPI_AWARE = True
except Exception:
    DPI_AWARE = False


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


def get_cursor():
    p = POINT()
    ctypes.windll.user32.GetCursorPos(ctypes.byref(p))
    return p.x, p.y


def screen_metrics():
    u = ctypes.windll.user32
    u.GetSystemMetrics.argtypes = [ctypes.c_int]
    u.GetSystemMetrics.restype = ctypes.c_int
    return u.GetSystemMetrics(0), u.GetSystemMetrics(1)   # SM_CXSCREEN / SM_CYSCREEN


def find_project_root():
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "..", "..", "采集器", "微信公众号ocr采集器"),
        r"Z:\library\巧克力加工厂\采集器\微信公众号ocr采集器",
        here,
        os.path.join(here, ".."),
    ]
    for c in candidates:
        c = os.path.abspath(c)
        if os.path.isfile(os.path.join(c, "backend", "app", "core", "computer.py")):
            return c
    return None


def main():
    print("=" * 64)
    print(" 坐标一致性校验：  悬浮窗显示的坐标  vs  采集器 mouse_click 落点")
    print("=" * 64)
    print(f" DPI 感知 : {'已开启（物理像素）' if DPI_AWARE else '未开启（可能被系统缩放）'}")
    sw, sh = screen_metrics()
    print(f" 物理分辨率: {sw} x {sh}")
    print()

    root = find_project_root()
    if not root:
        print("[跳过实测] 未找到采集器项目（含 backend/app/core/computer.py）")
        return 2
    backend_dir = os.path.join(root, "backend")
    sys.path.insert(0, backend_dir if os.path.isdir(backend_dir) else root)
    try:
        from app.core import computer as pc  # noqa: E402
    except Exception as e:
        print(f"[跳过实测] 导入 computer 模块失败: {e}")
        return 2
    print(f" 采集器项目: {root}")
    print()

    # 组装测试点：当前光标（悬浮窗上的数）+ 屏幕几个固定点 + 命令行指定点
    cur = get_cursor()
    points = [("当前光标(悬浮窗显示值)", cur)]
    points.append(("屏幕中心", (sw // 2, sh // 2)))
    points.append(("左上 1/4", (sw // 4, sh // 4)))
    points.append(("右下 3/4", (sw * 3 // 4, sh * 3 // 4)))
    if len(sys.argv) >= 3:
        points.insert(0, ("命令行传入", (int(sys.argv[1]), int(sys.argv[2]))))

    worst = 0
    results = []
    for name, (tx, ty) in points:
        # 先挪到角落，确保落点不是"本来就在那"
        pc.mouse_click(max(1, sw - 3), max(1, sh - 3), show_feedback=False, hold_ms=0)
        time.sleep(0.08)
        pc.mouse_click(tx, ty, show_feedback=False, hold_ms=20)
        time.sleep(0.12)
        gx, gy = get_cursor()
        dx, dy = gx - tx, gy - ty
        worst = max(worst, abs(dx), abs(dy))
        results.append((name, (tx, ty), (gx, gy), (dx, dy)))
        print(f"  {name:<22} 目标 ({tx:>4},{ty:>4})  →  落点 ({gx:>4},{gy:>4})   偏差 ({dx:+d},{dy:+d})")

    print()
    print("-" * 64)
    if worst == 0:
        print(" 结论：完全一致 ✓")
        print("       悬浮窗上看到的坐标，采集器 mouse_click 会落在同一点，可直接抄进点位表。")
    elif worst <= 1:
        print(f" 结论：一致（最大偏差 {worst}px，属系统像素取整，对点击无影响）✓")
        print("       可以放心用悬浮窗读数配置点位。")
    else:
        print(f" 结论：存在系统性偏移 ✗  最大偏差 {worst}px")
        print("       请检查两端是否都调用了 SetProcessDPIAware()，以及是否同一显示器。")
    print("-" * 64)

    # 还原光标到用户原来的位置
    try:
        ctypes.windll.user32.SetCursorPos(cur[0], cur[1])
    except Exception:
        pass
    return 0 if worst <= 1 else 1


if __name__ == "__main__":
    sys.exit(main())
