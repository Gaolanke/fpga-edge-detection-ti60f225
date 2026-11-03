`timescale 1ns/1ps
//==============================================================================
// tb_key_ctrl.v — 按键消抖 / 短按 / 长按时序回归
//
// 背景 (2026-11-03): 实板踩坑——长按门槛、去抖宽度、long_fired 锁存都没被仿真覆盖,
// 按键丝印错位问题排查时一度怀疑时序参数错误. 本用例把这些行为固化:
//   1. 短按 (< LONG_MS) 恰好产生 1 个 o_short 单脉冲, 不产生 o_long
//   2. 长按在 去抖(DB_MS) + LONG_MS 时刻产生 1 个 o_long, 且松开后不再补 o_short
//   3. 小于去抖宽度的抖动毛刺不产生任何事件
//   4. 一直按住只触发一次长按 (long_fired 锁存)
//   5. o_down 输出跟随去抖后的电平
//
// 时钟缩放: CLK_HZ = 1 MHz (真实 148.5 MHz / 148.5), DB_MS/LONG_MS 比例不变,
// 计数器行为与真实频率完全同构, 仿真速度快 ~150 倍.
//==============================================================================
module tb_key_ctrl;
    localparam integer CLK_HZ  = 1_000_000;   // 缩放时钟: 148.5MHz/148.5
    localparam integer DB_MS   = 15;
    localparam integer LONG_MS = 400;

    reg  clk   = 1'b0;
    reg  rst_n = 1'b0;
    reg  key_n = 1'b1;          // 低有效: 按下 = 0
    wire o_short, o_long, o_down;

    integer n_short = 0;
    integer n_long  = 0;
    integer errors  = 0;
    realtime t_press = 0.0;
    realtime t_long  = 0.0;

    key_ctrl #(
        .CLK_HZ  (CLK_HZ),
        .DB_MS   (DB_MS),
        .LONG_MS (LONG_MS)
    ) u_dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .key_n   (key_n),
        .o_short (o_short),
        .o_long  (o_long),
        .o_down  (o_down)
    );

    always #500 clk = ~clk;    // 1 MHz

    always @(posedge clk) begin
        if (o_short) n_short <= n_short + 1;
        if (o_long) begin
            n_long <= n_long + 1;
            t_long <= $realtime;
        end
    end

    task check(input cond, input [255:0] name);
        if (!cond) begin
            errors = errors + 1;
            $display("FAIL: %0s (short=%0d long=%0d)", name, n_short, n_long);
        end
    endtask

    // 按住 hold_ms 后松开, 再静默 60ms 让松开去抖走完
    task press_hold(input realtime hold_ms);
    begin
        t_press = $realtime;
        key_n   = 1'b0;
        #(hold_ms * 1.0e6);
        key_n   = 1'b1;
        #60.0e6;
    end
    endtask

    initial begin
        #1000 rst_n = 1'b1;
        #1000;

        // --- 用例 1: 短按 100ms -> 恰好 1 个短按, 无长按 ---
        press_hold(100.0);
        check(n_short == 1, "case1_short_fires_once");
        check(n_long  == 0, "case1_no_long_on_short_press");
        check(o_down == 1'b0, "case1_released_level_low");

        // --- 用例 2: 长按 600ms -> 1 个长按, 时刻 ~= 15ms(去抖)+400ms ---
        press_hold(600.0);
        check(n_long  == 1, "case2_long_fires_once");
        check(n_short == 1, "case2_no_short_after_long");
        check((t_long - t_press) > 413.0e6, "case2_long_not_early");
        check((t_long - t_press) < 417.0e6, "case2_long_not_late");

        // --- 用例 3: 抖动毛刺 (每段 < 15ms 去抖宽度) 不产生任何事件 ---
        begin : bounce
            integer k;
            for (k = 0; k < 8; k = k + 1) begin
                key_n = 1'b0; #(3.0e6);
                key_n = 1'b1; #(5.0e6);
            end
            #60.0e6;
        end
        check(n_short == 1, "case3_bounce_no_short");
        check(n_long  == 1, "case3_bounce_no_long");

        // --- 用例 4: 按住 1000ms 只触发一次长按 (long_fired 锁存) ---
        press_hold(1000.0);
        check(n_long  == 2, "case4_long_once_per_hold");
        check(n_short == 1, "case4_still_no_short");

        // --- 用例 5: 再来一次正常短按, 计数继续累加 ---
        press_hold(50.0);
        check(n_short == 2, "case5_short_counts_again");

        if (errors == 0)
            $display("RESULT: PASS (key_ctrl: debounce/short/long, %0d short, %0d long)", n_short, n_long);
        else
            $display("RESULT: FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
