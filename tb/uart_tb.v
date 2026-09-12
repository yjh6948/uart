`timescale 1ns / 1ps

module uart_tb;

    localparam CLK_FREQ  = 100_000_000;
    localparam BAUD_RATE = 115_200;
    localparam CLK_PERIOD = 10; // 100 MHz
    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    reg        clk;
    reg        rst_n;
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;
    wire       tx_serial;

    wire       rx_done;
    wire [7:0] rx_data;
    wire       frame_error;

    // second, independently-driven RX instance used only for the
    // manually-crafted bad-frame test (can't inject a bad stop bit
    // through the loopback path since tx always drives a good one)
    reg        drive_rx;
    wire       rx2_done;
    wire [7:0] rx2_data;
    wire       rx2_frame_error;

    integer errors = 0;
    integer i;

    uart_tx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) dut_tx (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx_busy(tx_busy),
        .tx_serial(tx_serial)
    );

    // loopback: tx output feeds rx input directly
    uart_rx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) dut_rx (
        .clk(clk),
        .rst_n(rst_n),
        .rx_serial(tx_serial),
        .rx_done(rx_done),
        .rx_data(rx_data),
        .frame_error(frame_error)
    );

    uart_rx #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) dut_rx2 (
        .clk(clk),
        .rst_n(rst_n),
        .rx_serial(drive_rx),
        .rx_done(rx2_done),
        .rx_data(rx2_data),
        .frame_error(rx2_frame_error)
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    task send_byte(input [7:0] data);
        begin
            @(posedge clk);
            tx_data  = data;
            tx_start = 1'b1;
            @(posedge clk);
            tx_start = 1'b0;
            wait (rx_done == 1'b1);
            @(posedge clk);
            if (rx_data !== data) begin
                $display("FAIL: sent 0x%02h, received 0x%02h", data, rx_data);
                errors = errors + 1;
            end
            wait (tx_busy == 1'b0);
        end
    endtask

    // Fires the next tx_start the instant tx_busy drops, with no
    // extra idle gap, to stress back-to-back framing.
    task send_byte_no_gap(input [7:0] data);
        begin
            wait (tx_busy == 1'b0);
            @(posedge clk);
            tx_data  = data;
            tx_start = 1'b1;
            @(posedge clk);
            tx_start = 1'b0;
            wait (rx_done == 1'b1);
            @(posedge clk);
            if (rx_data !== data) begin
                $display("FAIL [back-to-back]: sent 0x%02h, received 0x%02h", data, rx_data);
                errors = errors + 1;
            end
        end
    endtask

    // Bit-bang a raw UART frame directly onto dut_rx2, with a
    // caller-chosen stop bit value (bad_stop=1 -> corrupted frame).
    task send_manual_frame(input [7:0] data, input bad_stop);
        integer b;
        begin
            drive_rx = 1'b1;
            repeat (CLKS_PER_BIT) @(posedge clk);
            drive_rx = 1'b0; // start bit
            repeat (CLKS_PER_BIT) @(posedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                drive_rx = data[b];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            drive_rx = bad_stop ? 1'b0 : 1'b1; // stop bit
            repeat (CLKS_PER_BIT) @(posedge clk);
            drive_rx = 1'b1; // back to idle
        end
    endtask

    initial begin
        $dumpfile("uart_tb.vcd");
        $dumpvars(0, uart_tb);

        clk      = 0;
        rst_n    = 0;
        tx_start = 0;
        tx_data  = 0;
        drive_rx = 1;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // --- 1. Exhaustive test: every possible byte value, 0x00-0xFF ---
        for (i = 0; i < 256; i = i + 1) begin
            send_byte(i[7:0]);
        end
        $display("Exhaustive 256-byte loopback: %0d errors so far", errors);

        // --- 2. Back-to-back framing: no idle gap between frames ---
        send_byte_no_gap(8'h5A);
        send_byte_no_gap(8'hC3);
        send_byte_no_gap(8'h81);
        send_byte_no_gap(8'h00);
        $display("Back-to-back framing: %0d errors so far", errors);

        // --- 3. Good manually-crafted frame -> no frame error ---
        // (rx2_done pulses mid-stop-bit, inside the task itself, so by
        // the time the task returns the pulse has already come and gone
        // -- check the latched outputs directly instead of re-waiting)
        send_manual_frame(8'h7E, 1'b0);
        if (rx2_frame_error !== 1'b0 || rx2_data !== 8'h7E) begin
            $display("FAIL [good frame]: data=0x%02h frame_error=%0b", rx2_data, rx2_frame_error);
            errors = errors + 1;
        end else begin
            $display("PASS [good frame]: data=0x%02h frame_error=%0b", rx2_data, rx2_frame_error);
        end

        // --- 4. Corrupted stop bit -> frame_error must assert ---
        send_manual_frame(8'h3C, 1'b1);
        if (rx2_frame_error !== 1'b1) begin
            $display("FAIL [bad stop bit]: expected frame_error=1, got %0b", rx2_frame_error);
            errors = errors + 1;
        end else begin
            $display("PASS [bad stop bit]: frame_error correctly asserted");
        end

        if (errors == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("%0d TEST(S) FAILED", errors);
        end

        $finish;
    end

endmodule
