/*
 * ECP5 flash emulator
 */
`default_nettype none
`include "uart.v"
`include "pll_132.v"
`include "sdram_ctrl.v"
`include "spi_device.v"
`include "spi_flash.v"
`include "user.v"

module top(
	input clk_25mhz,
	output [7:0] led,
	output wifi_gpio0,
	input ftdi_txd, // from the ftdi chip
	output ftdi_rxd, // to the ftdi chip

	// sdram physical interface
	output [12:0] sdram_a,
	inout [15:0] sdram_d,
	output [1:0] sdram_ba,
	output sdram_clk,
	output sdram_cke,
	output sdram_wen,
	output sdram_csn,
	output [1:0] sdram_dqm,
	output sdram_rasn,
	output sdram_casn,

	// GPIO pins, to be assigned
	inout [27:0] gp,
	inout [27:0] gn,

	// buttons for user io
	input [6:0] btn,
);
	// gpio0 must be tied high to prevent board from rebooting
	assign wifi_gpio0 = 1;

	reg [7:0] led_reg;
	assign led = led_reg;

	// Generate a 132 MHz clock from the 25 MHz reference
	// with a 180 degree out of phase sdram clk
	wire clk_132, clk_132_180, locked, reset = !locked || btn[1];
	pll_132 pll_132_i(clk_25mhz, clk_132, clk_132_180, locked);
	//pll_96 pll_132_i(clk_25mhz, clk_132, clk_132_180, locked);
	wire clk = clk_132;
	wire sdram_clk = clk_132_180; // sdram needs to be stable on the rising edge

	// SPI bus is on the J2 positive pins
	wire spi_cs_pin = gp[20];
	wire spi_clk_pin = gp[19];
	wire spi_mosi_pin = gp[18];
	wire spi_miso_pin = gp[17];
	wire spi_cs_out_pin = gp[16]; // for toctou on a flash without pullup

	wire ENABLE_EMULATION = 1;
	wire ENABLE_TOCTOU = 0; // if there is an existing flash that we're modifying

	// !CS is driven high if we are in TOCTOU mode since the existing flash
	// chip needs to be turned off.
	wire spi_cs_enable = spi_critical && !spi_timeout && ENABLE_EMULATION && ENABLE_TOCTOU;
	// MISO is driven high if we are in emulation mode or TOCTOU mode
	//wire spi_miso_enable = spi_critical && !spi_timeout && ENABLE_EMULATION;
	wire spi_miso_enable = spi_critical && ENABLE_EMULATION;

	// if we are driving !CS high, we have to fake a low !CS for the other
	// parts of our logic.
	wire spi_cs_fake = ENABLE_TOCTOU && spi_cs_enable ? 1'b0 : spi_cs_in;

	wire spi_miso_out;
	wire spi_miso_in;
	wire spi_mosi_in;
	wire spi_clk_in;
	wire spi_cs_in;

	wire [7:0] spi_rx_data;
	wire spi_rx_cmd;
	wire spi_rx_strobe;
	wire spi_rx_bit_strobe;
	wire [2:0] spi_rx_bit;
	wire spi_timeout;

`define EMU
`ifdef EMU
	TRELLIS_IO #(.DIR("BIDIR")) spi_cs_buf(
		.T(!spi_cs_enable),
		.B(spi_cs_pin),
		.I(1), // always high output for TOCTOU, 
		.O(spi_cs_in),
	);
	TRELLIS_IO #(.DIR("BIDIR")) spi_miso_buf(
		.T(!spi_miso_enable),
		.B(spi_miso_pin),
		.I(spi_miso_out),
		.O(spi_miso_in),
	);
	TRELLIS_IO #(.DIR("OUTPUT")) spi_cs_out_buf(
		.B(spi_cs_out_pin),
		.I(1), // never select the other flash
	);
`else
	TRELLIS_IO #(.DIR("INPUT")) spi_cs_buf(
		.T(!spi_cs_enable),
		.B(spi_cs_pin),
		.I(1), // always high output for TOCTOU, 
		.O(spi_cs_in),
	);
	TRELLIS_IO #(.DIR("INPUT")) spi_miso_buf(
		.T(!spi_miso_enable),
		.B(spi_miso_pin),
		.I(spi_miso_out),
		.O(spi_miso_in),
	);
	TRELLIS_IO #(.DIR("OUTPUT")) spi_cs_out_buf(
		.B(spi_cs_out_pin),
		.I(spi_cs_in), // copy the input pin to the output
	);
`endif
	TRELLIS_IO #(.DIR("INPUT")) spi_mosi_buf(
		.B(spi_mosi_pin),
		.O(spi_mosi_in),
	);
	TRELLIS_IO #(.DIR("INPUT")) spi_clk_buf(
		.B(spi_clk_pin),
		.O(spi_clk_in),
	);

	wire spi_tx_strobe;
	wire [7:0] spi_tx_data;

	// we could special case the read command to fetch *both bytes*
	// once we have 7 of the 8 bits....
	spi_device spi_i(
		.clk(clk),
		.reset(reset),
		// physical interface, in spi_clk domain
		.spi_cs(spi_cs_fake),
		.spi_clk(spi_clk_in),
		.spi_miso(spi_miso_out),
		.spi_mosi(spi_mosi_in),
		// bit-wise interface, in the local clk for faster prefetch
		.spi_rx_bit(spi_rx_bit),
		.spi_rx_bit_strobe(spi_rx_bit_strobe),
		// byte wise interface, in the local clk
		.spi_rx_data(spi_rx_data),
		.spi_rx_cmd(spi_rx_cmd),
		.spi_rx_strobe(spi_rx_strobe),
		.spi_tx_data(spi_tx_data),
		.spi_tx_strobe(spi_tx_strobe),
		.spi_timeout(spi_timeout)
	);

	// flag for when we have timing critical spi transaction
	// there is a race condition with asserting this while the bus is busy
	// so don't mix serial operations with booting the machine right now
	wire spi_critical;
	wire spi_refresh_inhibit;

	// these will be written to the serial port
	wire [31:0] spi_log_addr;
	wire [7:0] spi_log_len;
	wire spi_log_strobe;
	wire [7:0] spi_errors;

	// interface to the memory
	wire [31:0] spi_read_addr;
	wire [7:0] spi_read_data;
	wire spi_read_enable;

	spi_flash spi_f(
		.clk(clk),
		.reset(reset),

		// spi bus interface
		.spi_cs(spi_cs_fake),
		.spi_rx_data(spi_rx_data),
		.spi_rx_cmd(spi_rx_cmd),
		.spi_rx_strobe(spi_rx_strobe),
		.spi_rx_bit(spi_rx_bit),
		.spi_rx_bit_strobe(spi_rx_bit_strobe),
		.spi_tx_strobe(spi_tx_strobe),
		.spi_tx_data(spi_tx_data),

		// memory interface
		.spi_critical(spi_critical),
		.ram_refresh_inhibit(spi_refresh_inhibit),
		.ram_addr(spi_read_addr),
		.ram_read_enable(spi_read_enable), // when an address has been received
		.ram_read_data(sd_rd_data),
		.ram_read_valid(sd_ack),

		// logging interface
		.log_strobe(spi_log_strobe),
		.log_addr(spi_log_addr),
		.log_len(spi_log_len),
		.errors(spi_errors),
	);

	// oscilloscope debug pins also on jp2
	wire debug_0 = spi_miso_in;
	wire debug_1 = sd_ack; // spi_miso_out;
	reg trigger;
	TRELLIS_IO #(.DIR("OUTPUT")) debug0(.B(gp[26]), .I(trigger));
	TRELLIS_IO #(.DIR("OUTPUT")) debug2(.B(gp[27]), .I(debug_0));
	TRELLIS_IO #(.DIR("OUTPUT")) debug3(.B(gp[25]), .I(debug_1));

	// serial port interface for talking to the host system
	// 132 MHz clock / 48 == 3 megabaud
	wire uart_txd_ready;
	reg [7:0] uart_txd;
	reg uart_txd_strobe;
	wire uart_rxd_strobe;
	wire [7:0] uart_rxd;

	uart #(
		.DIVISOR(132 / 3), // 132 MHz
		//.DIVISOR(96 / 3),
		.FIFO(65536),
		.FREESPACE(16),
	) uart_i(
		.clk(clk),
		.reset(reset),
		// physical
		.serial_txd(ftdi_rxd), // fpga --> ftdi
		.serial_rxd(ftdi_txd), // fpga <-- ftdi
		// logical
		.txd(uart_txd),
		.txd_ready(uart_txd_ready),
		.txd_strobe(uart_txd_strobe),
		.rxd(uart_rxd),
		.rxd_strobe(uart_rxd_strobe),
	);

	// sdram logical interface has a 16-bit data interface
	parameter ADDR_WIDTH = 24;
	parameter DATA_WIDTH = 16;
	wire [DATA_WIDTH-1:0] sd_rd_data;
	//wire [DATA_WIDTH-1:0] sd_rd_data_raw;

	// the serial user interface has a lower priority access to the sdram
	wire user_sd_we;
	wire user_sd_enable;
	wire [1:0] user_sd_wr_mask;
	wire [31:0] user_sd_addr;
	wire [DATA_WIDTH-1:0] user_sd_wr_data;

	// the spi bus can take control of the ram by asserting the spi_critical
	// signal, which takes over all of the inputs
	// note that right now the sdram is 16-bit wide, but we read only the bottom byte
	// so it is necessary to shift the address by 1
	wire sd_we = spi_critical ? 1'b0 : user_sd_we;
	wire sd_enable = spi_critical ? spi_read_enable : user_sd_enable;
	wire [31:0] sd_addr = spi_critical ? spi_read_addr : user_sd_addr;
	wire [DATA_WIDTH-1:0] sd_wr_data = spi_critical ? 16'hDEAD : user_sd_wr_data;
	wire [1:0] sd_wr_mask = spi_critical ? 2'b00 : user_sd_wr_mask;

	// convert the sd_ack signal from a level to an edge sensitive
	reg sd_ack_prev;
	wire sd_ack = sd_ack_level && !sd_ack_prev;
	wire sd_ack_level;
	always @(posedge clk) sd_ack_prev <= sd_ack_level;

	//wire sd_ack_raw;
	wire sd_idle;

	wire	[15:0]	sdram_dq_i;
	wire	[15:0]	sdram_dq_o;
	wire		sdram_dq_oe;

	// generate an sdram reset controller
	wire sd_refresh_inhibit = spi_critical && spi_refresh_inhibit;
	wire sd_pause_read = 0;
	reg [15:0] sdram_reset_counter;
	wire sdram_reset = sdram_reset_counter != 0;
	always @(posedge clk or posedge reset)
		if (reset)
			sdram_reset_counter <= ~0;
		else
		if (sdram_reset)
			sdram_reset_counter <= sdram_reset_counter - 1;

	// the dq pins are bidirectional and controlled by the dq_oe signal
	genvar i;
	generate
	for(i=0 ; i < DATA_WIDTH ; i=i+1)
		TRELLIS_IO #(.DIR("BIDIR")) sdram_d_buf(
			.T(!sdram_dq_oe),
			.B(sdram_d[i]),
			.I(sdram_dq_o[i]),
			.O(sdram_dq_i[i]),
		);
	endgenerate

////////////////////////////////////////////////////////////////////////
//
// SDRAM Memory Controller
//
////////////////////////////////////////////////////////////////////////

sdram_ctrl #(
	.CLK_FREQ_MHZ			(132),	// sdram_clk freq in MHZ
	.POWERUP_DELAY			(200),	// power up delay in us
	.REFRESH_MS			(32),	// delay between refresh cycles im ms
	.BURST_LENGTH			(1),	// 1 read at a time
	.ROW_WIDTH			(13),	// Row width
	.COL_WIDTH			(9),	// Column width
	.BA_WIDTH			(2),	// Ba width
	.tCAC				(2),	// CAS Latency
	.tRAC				(5),	// RAS Latency
	.tRP				(2),	// Command Period (PRE to ACT)
	.tRC				(7),	// Command Period (REF to REF / ACT to ACT)
	.tMRD				(2)	// Mode Register Set To Command Delay time
)
sdram_ctrl0 (
	// External SDRAM interface
	.ba_o		(sdram_ba),
	.a_o		(sdram_a),
	.cs_n_o		(sdram_csn),
	.ras_o		(sdram_rasn),
	.cas_o		(sdram_casn),
	.we_o		(sdram_wen),
	.dq_i		(sdram_dq_i),
	.dq_o		(sdram_dq_o),
	.dqm_o		(sdram_dqm),
	.dq_oe_o	(sdram_dq_oe),
	.cke_o		(sdram_cke),
	.sdram_clk	(clk), // sdram_clk is the output to the chip
	.sdram_rst	(sdram_reset),

	// logical interface
	.idle_o		(sd_idle),
	.adr_i		(sd_addr),
	.dat_i		(sd_wr_data),
	.sel_i		(sd_wr_mask),
	.acc_i		(sd_enable),
`define SLOW_RD
`ifdef SLOW_RD
	.dat_o		(sd_rd_data),
	.ack_o		(sd_ack_level),
`else
	.dat_raw	(sd_rd_data),
	.ack_raw	(sd_ack),
`endif
	.we_i		(sd_we),
	.refresh_inhibit_i(sd_refresh_inhibit),
	.pause_read_i	(sd_pause_read)
);

	// Serial port user interface
	wire [7:0] user_txd;
	wire user_txd_strobe;
	wire user_txd_ready = spi_critical ? 1'b0 : uart_txd_ready;

	user_command_parser user(
		.clk(clk),
		.reset(reset),
		// serial port interface
		.uart_rxd(uart_rxd),
		.uart_rxd_strobe(uart_rxd_strobe),
		.uart_txd(user_txd),
		.uart_txd_strobe(user_txd_strobe),
		.uart_txd_ready(user_txd_ready),

		// sdram interface
		.sd_addr(user_sd_addr),
		.sd_we(user_sd_we),
		.sd_wr_mask(user_sd_wr_mask),
		.sd_enable(user_sd_enable),
		.sd_wr_data(user_sd_wr_data),
		.sd_rd_data(sd_rd_data),
		.sd_ack(spi_critical ? 1'b0 : sd_ack),
		.sd_idle(spi_critical ? 1'b0 : sd_idle),
	);

	reg [3:0] uart_words;
	reg [63:0] uart_word;
	reg user_sd_enable_prev;
	always @(posedge clk) user_sd_enable_prev <= user_sd_enable;
	wire user_sd_enable_rising = user_sd_enable && !user_sd_enable_prev;

	reg [4:0] counter;

	reg [1:0] spi_cs_prev;
	reg spi_cs_falling = spi_cs_prev[1] && !spi_cs_prev[0];
	always @(posedge clk) spi_cs_prev <= { spi_cs_prev[0], spi_cs_in };

	parameter LOG_ALL_BYTES = 0;
	parameter VERBOSE_LOGGING = 0;

	always @(posedge clk)
	begin
		uart_txd_strobe <= 0;
		if (counter == 0)
			trigger <= 0;
		else
			counter <= counter - 1;

		if (reset) begin
			// anything to do?
			counter <= 0;
		end else
		if (uart_rxd_strobe)
		begin
			led_reg <= uart_rxd;
		end else
		
		if (spi_log_strobe) // && uart_txd_ready)
		begin
			// a SPI transaction has just occured;
			// write it to the serial port if there is space
			if (VERBOSE_LOGGING) begin
				uart_word <= { "READ", spi_log_addr[23:0], spi_log_len };
			//if (spi_log_addr[23:16] == 8'h18)
				uart_words <= 8;
			end else begin
				uart_word <= { spi_log_addr[23:0], spi_log_len, 32'b0 };
				uart_words <= 4;
			end

			//led_reg <= spi_log_addr[11:4];

			counter <= ~0;

			if (spi_log_addr[23:0] == 24'h000010)
			//if (spi_log_addr[23:0] == 24'h001810)
			begin
				trigger <= 1;
			end
		end else
		if (uart_words != 0) // && uart_txd_ready)
		begin
			uart_words <= uart_words - 1;
			uart_txd_strobe <= 1;
			uart_txd <= uart_word[63:56];
			uart_word <= uart_word << 8;
		end else
		if (spi_tx_strobe && LOG_ALL_BYTES)
		begin
			uart_txd_strobe <= 1;
			uart_txd <= spi_log_len; // spi_tx_data;
		end else
		if (user_txd_strobe && uart_txd_ready)
		begin
			uart_txd_strobe <= 1;
			uart_txd <= user_txd;
		end else begin
			led_reg[0] <= spi_cs_in;
			led_reg[1] <= spi_critical;
			led_reg[3] <= sd_we;
			led_reg[7:4] <= spi_errors[7:4];
		end
	end
endmodule
