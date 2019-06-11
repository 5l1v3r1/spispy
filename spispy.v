/** \file
 * SPI bus emulator.
 *
 * This uses the onboard DRAM to store a flash image and can provide
 * it over a SPI bus to an external device.
 *
 * This also configures the serial port at 3 Mb/s for the command
 * protocol in user.v.
 *
 * FLCOMP in the IFD should be adjusted to use single SPI at 17 MHz.
 * Offset 0x30.  SPI_FREQUENCY_17MHZ=6 SPI_FREQUENCY_20MHZ=0
 * bit 30 = 0 == no dual fast read support
 * bit 20 = 0 == no fast read support
 * speed offsets 17, 21, 24, 27
 * 0x00 10 00 24
 *
 * 20 17
 * 1 000 00000000000100100
 *
 * minnow board dediprog pinout:
 *             VCC  GND    Black
 *      White  CS   CLK    Green / Orange
 *      Brown  MISO MOSI   Yellow
 *             NC   NC
 */
`default_nettype none
`include "util.v"
`include "uart.v"
`include "gpio.v"
`include "pll_96.v"
`include "sdram_controller.v"
`include "user.v"
`include "spi_device.v"

module top(
	input clk_100mhz,
	//inout [7:0] pmod1, // serial port
	output pmod1_0,
	input pmod1_1,
	output pmod1_2,
	output pmod1_3,
	output pmod1_4,
	output pmod1_5,
	inout [7:0] pmod2, // spi flash clip

	// SDRAM physical interface
	output [12:0] sdram_addr,
	inout [7:0] sdram_data,
	output [1:0] sdram_bank,
	output sdram_clk,
	output sdram_cke,
	output sdram_we,
	output sdram_cs,
	output sdram_dqm,
	output sdram_ras,
	output sdram_cas
);
	// beaglewire pinouts
	wire serial_txd_pin	= pmod1_0; // pmod1[0];
	wire serial_rxd_pin	= pmod1_1; // pmod1[1];

	wire spi_clk_pin	= pmod2[0];
	wire spi_cs_pin		= pmod2[1];
	wire spi_miso_pin	= pmod2[2];
	wire spi_mosi_pin	= pmod2[3];


	wire locked, clk_96mhz, clk;
	wire reset = !locked;
	pll_96 pll(clk_100mhz, clk_96mhz, locked);
	assign clk = clk_96mhz;

	parameter ADDR_BITS = 25; // 32 MB SDRAM chip

	// arbitrate between the user commands and the SPI bus when
	// we're in a critcal section.
	reg spi_critical;
	reg [ADDR_BITS-1:0] spi_sd_addr;
	wire [7:0] spi_sd_wr_data = 0;
	reg spi_sd_enable;
	wire spi_sd_we = 0;
	wire spi_sd_busy = sd_busy;
	wire spi_rd_ready = spi_critical ? sd_rd_ready : 0;
	wire spi_sd_refresh_inhibit = spi_critical;

	wire [ADDR_BITS-1:0] user_sd_addr;
	wire [7:0] user_sd_wr_data;
	wire user_sd_enable;
	wire user_sd_we;
	wire user_sd_busy = spi_critical ? 1 : sd_busy;
	wire user_rd_ready = spi_critical ? 0 : sd_rd_ready;
	wire user_sd_refresh_inhibit;

	// sdram logical interface
	wire [ADDR_BITS-1:0] sd_addr = spi_critical ? spi_sd_addr : user_sd_addr;
	wire [7:0] sd_wr_data = spi_critical ? spi_sd_wr_data : user_sd_wr_data;
	wire [7:0] sd_rd_data;
	wire sd_we = spi_critical ? spi_sd_we : user_sd_we;
	wire sd_enable = spi_critical ? spi_sd_enable : user_sd_enable;
	wire sd_refresh_inhibit = spi_critical ? spi_sd_refresh_inhibit : user_sd_refresh_inhibit;

	wire sd_rd_ready;
	wire sd_busy;
	assign sdram_clk = clk;

	sdram_controller sdram(
		.clk(clk),
		.rst_n(!reset),

		// physical interface
		.addr(sdram_addr),
		.bank_addr(sdram_bank),
		.data(sdram_data),
		.clock_enable(sdram_cke),
		.cs_n(sdram_cs),
		.ras_n(sdram_ras),
		.cas_n(sdram_cas),
		.we_n(sdram_we),
		.data_mask(sdram_dqm),

		// logical interface
		.refresh_inhibit(sd_refresh_inhibit),
		.wr_addr(sd_addr),
		.wr_enable(sd_enable & sd_we),
		.wr_data(sd_wr_data),
		.rd_addr(sd_addr),
		.rd_enable(sd_enable & !sd_we),
		.rd_data(sd_rd_data),
		.rd_ready(sd_rd_ready),
		.busy(sd_busy),
	);

	wire serial_txd;
	wire serial_rxd;

	gpio gpio_txd(
		.enable(1), // always on
		.pin(serial_txd_pin),
		.out(serial_txd),
	);

	gpio #(.PULLUP(1)) gpio_rxd(
		.enable(0), // always input, with pullup
		.pin(serial_rxd_pin),
		.in(serial_rxd),
		.out(1),
	);


	// generate a 3 MHz/12 MHz serial clock from the 96 MHz clock
	// this is the 3 Mb/s maximum supported by the FTDI chip
	// note that some Linux tools can have trouble keeping up with
	// this data rate; xxd -g1 for instance will drop bytes on
	// long bursts (more than 1KB).
	wire clk_3mhz, clk_12mhz;
`ifdef CLK48
	divide_by_n #(.N(4)) div1(clk, reset, clk_12mhz);
	divide_by_n #(.N(16)) div4(clk, reset, clk_3mhz);
`else
	//divide_by_n #(.N(8)) div1(clk, reset, clk_12mhz);
	//divide_by_n #(.N(32)) div4(clk, reset, clk_3mhz);

	// 1 megabaud
	divide_by_n #(.N(24)) div1(clk, reset, clk_12mhz);
	divide_by_n #(.N(96)) div4(clk, reset, clk_3mhz);
`endif

	wire [7:0] uart_rxd;
	wire uart_rxd_strobe;
	wire uart_txd_ready;
	reg [7:0] uart_txd;
	reg uart_txd_strobe;

`define UART_FIFO
`ifdef UART_FIFO
	uart_tx_fifo #(
		.NUM(512),
		.FREESPACE(15'h32), // ensure there is always space
	)
`else
	uart_tx
`endif
	txd (
		.clk(clk),
		.reset(reset),
		.baud_x1(clk_3mhz),
		.serial(serial_txd),
		.data(uart_txd),
		.data_strobe(uart_txd_strobe),
		.ready(uart_txd_ready)
	);

	uart_rx rxd(
		.clk(clk),
		.reset(reset),
		.baud_x4(clk_12mhz),
		.serial(serial_rxd),
		.data(uart_rxd),
		.data_strobe(uart_rxd_strobe)
	);

	// SPI flash
	// in spispy mode all of them are inputs.
	// in toctou mode the cs and miso are output;
	// cs is driven high to deselect the flash chip
	// and miso is driven with the fpga provided data
	reg spi_tristate = 0;

	// if we're faking the !CS pin (driving the output high)
	// tell our SPI device that it is still selected.
	reg spi_cs_enable = 0;
	wire fake_spi_cs = spi_cs_enable ? 0 : spi_cs_in;

	reg spi_cs_out = 1; // always high
	reg spi_clk_out = 0;
	reg spi_mosi_out = 0;
	wire spi_miso_out; // controlled by spi_device

	wire spi_cs_in;
	wire spi_clk_in;
	wire spi_mosi_in;
	wire spi_miso_in;

	gpio gpio_spi_cs(
		.enable(spi_tristate & spi_cs_enable),
		.pin(spi_cs_pin),
		.in(spi_cs_in),
		.out(spi_cs_out),
	);

	gpio gpio_spi_clk(
		.enable(0), // always input, until we have a reader built in
		.pin(spi_clk_pin),
		.in(spi_clk_in),
		.out(spi_clk_out),
	);

	gpio gpio_spi_mosi(
		.enable(0), // always input, until we have a reader
		.pin(spi_mosi_pin),
		.in(spi_mosi_in),
		.out(spi_mosi_out),
	);

	gpio gpio_spi_miso(
		.enable(spi_tristate & spi_cs_enable),
		.pin(spi_miso_pin),
		.in(spi_miso_in),
		.out(spi_miso_out),
	);

/*
	gpio gpio_debug1(
		.enable(1), // always on
		.pin(pmod1[2]),
		.out(spi_cs_pin)
	);
	gpio gpio_debug2(
		.enable(1), // always on
		.pin(pmod1[3]),
		.out(spi_clk_pin),
	);
*/
/*
	reg pmod1_2, pmod1_3; // , pmod1_4, pmod1_5;
	always @(posedge clk) begin
		//pmod1_2 <= spi_rx_strobe; //spi_cs_in;
		pmod1_3 <= spi_critical;
		pmod1_4 <= spi_miso_out;
		pmod1_5 <= spi_miso_in;
	end
*/
	assign pmod1_2 = spi_cs_in;
	assign pmod1_3 = spi_clk_in;
	assign pmod1_4 = spi_miso_out;
	assign pmod1_5 = spi_miso_in;

	//assign pmod1_2 = spi_cs_in;
	//assign pmod1_3 = spi_clk_in;

	// remember that this is clocked in spi_clk domain,
	// so it is not to be trusted.
	wire spi_rx_cmd_async;
	wire spi_rx_async;
	wire [7:0] spi_rx_data;
	reg [7:0] spi_tx_data = 0;

	spi_device spi(
		//.clk(clk),
		//.reset(reset),
		.spi_clk(spi_clk_in),
		.spi_cs(fake_spi_cs),
		.spi_miso(spi_miso_out),
		.spi_mosi(spi_mosi_in),
		.spi_rx_strobe(spi_rx_async),
		.spi_rx_cmd(spi_rx_cmd_async),
		.spi_rx_data(spi_rx_data),
		.spi_tx_data(spi_tx_data),
	);

	// spi_rx_cmd toggles in spi_clk domain, re-sync and strobify it
	reg [1:0] spi_rx_cmd_sync;
	reg [1:0] spi_rx_sync;
	reg [1:0] spi_cs_sync;
	wire spi_rx_cmd = spi_rx_cmd_sync[1] != spi_rx_cmd_sync[0];
	wire spi_rx_strobe = spi_rx_sync[1] != spi_rx_sync[0];
	always @(posedge clk) begin
		spi_rx_cmd_sync <= { spi_rx_cmd_sync[0], spi_rx_cmd_async };
		spi_rx_sync <= { spi_rx_sync[0], spi_rx_async };
		spi_cs_sync <= { spi_cs_sync[0], spi_cs_sync };
	end

	// serial output arbitrator between the user command
	// parser and the spi device decoder
	reg [7:0] spi_data_buffer;
	reg spi_data_pending;
	reg [7:0] user_data_buffer;
	reg user_data_pending;
	reg spi_critical;
	wire user_txd_strobe;
	wire [7:0] user_txd_data;
	wire user_txd_ready = !user_data_pending;

	reg [6:0] count = 0;
	reg [6:0] logging = 0;
	reg spi_log_this = 0; // don't add a new transaction if there is no space available

	reg [31:0] spi_cmd;
	reg spi_rd_cmd;
	reg spi_rd_pending;

	always @(posedge clk)
	begin
		uart_txd_strobe <= 0;

		spi_sd_enable <= 0;
`undef TEST
`ifdef TEST
		if (spi_rx_strobe) begin
			uart_txd <= spi_rx_data;
			uart_txd_strobe <= 1;
			count <= count + 1;
		end
`else
		if (spi_rx_strobe)
		begin
			if (spi_rx_cmd)
			begin
				// if there is no space, then stop logging
				spi_log_this <= uart_txd_ready;
				count <= 1;
				spi_cmd[31:24] <= spi_rx_data;
				spi_rd_cmd <= (spi_rx_data == 8'h03);
				spi_rd_pending <= 0;

				// Anytime the SPI CS line is asserted, take control
				// of the SD interface
				spi_critical <= 1;
				spi_tx_data <= 8'hF0;
			end else
			if (count == 1) begin
				spi_cmd[23:16] <= spi_rx_data;
				count <= 2;
				spi_tx_data <= 8'hF2;
			end else
			if (count == 2) begin
				spi_cmd[15: 8] <= spi_rx_data;
				count <= 3;
				spi_tx_data <= 8'hF6;
			end else
			if (count == 3) begin
				spi_cmd[ 7: 0] <= spi_rx_data;
				count <= 4;
				spi_data_pending <= 1;

				// we have the full address to process, read it
				spi_sd_addr <= { 1'b0, spi_cmd[23:8], spi_rx_data };
				if (spi_rd_cmd) begin
					if (sd_busy)
						spi_rd_pending <= 1;
					else
						spi_sd_enable <= 1;
				end
				spi_tx_data <= 8'hFF;
			end else begin
				// data to process, but we ignore it
				// should clock in a new byte from the SDRAM
			end
		end else
		if (spi_rd_pending && !sd_busy) begin
			// memory bus is free, start a read (probably too late)
			// should never happen
			spi_rd_pending <= 0;
			spi_sd_enable <= 1;
		end else
		if (sd_rd_ready) begin
			// the sdram has produced data, clock it to the SPI bus
			spi_tx_data <= sd_rd_data;
			spi_tx_data <= 8'h00;
		end
		if (spi_data_pending) begin
			if (count == 4)
				uart_txd <= spi_cmd[31:24];
			else
			if (count == 3)
				uart_txd <= spi_cmd[23:16];
			else
			if (count == 2)
				uart_txd <= spi_cmd[15: 8];
			else
			if (count == 1) begin
				uart_txd <= spi_cmd[ 7: 0];
				spi_data_pending <= 0;
			end

			count <= count - 1;
			uart_txd_strobe <= 1;

			// if we have received all zeros, don't output it
			if (spi_cmd == 0) begin
				spi_data_pending <= 0;
				uart_txd_strobe <= 0;
			end
		end else
		if (spi_cs_in) begin
			// no longer asserted
			spi_critical <= 0;
			spi_tx_data <= 8'hFF;
		end

		if (user_txd_strobe) begin
			user_data_buffer <= user_txd_data;
			user_data_pending <= 1;
		end else
		if (user_data_pending && uart_txd_ready && !spi_data_pending) begin
			uart_txd <= user_data_buffer;
			uart_txd_strobe <= 1;
			user_data_pending <= 0;
		end
`endif
	end


	// user command parser pulls in data from SPI
	// and from the serial port, drives the SDRAM
	user_command_parser #(
		.ADDR_BITS(ADDR_BITS)
	) parser(
		.clk(clk),
		.reset(reset),
		// serial I/O
		.uart_rxd(uart_rxd),
		.uart_rxd_strobe(uart_rxd_strobe),
		.uart_txd(user_txd_data),
		.uart_txd_strobe(user_txd_strobe),
		.uart_txd_ready(user_txd_ready),
		// SDRAM
		.sd_refresh_inhibit(user_sd_refresh_inhibit),
		.sd_addr(user_sd_addr),
		.sd_wr_data(user_sd_wr_data),
		.sd_rd_data(sd_rd_data),
		.sd_rd_ready(sd_rd_ready),
		.sd_we(user_sd_we),
		.sd_enable(user_sd_enable),
		.sd_busy(user_sd_busy),
	);
endmodule
