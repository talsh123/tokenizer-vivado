-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2026 Advanced Micro Devices, Inc. All Rights Reserved.
-- -------------------------------------------------------------------------------
-- This file contains confidential and proprietary information
-- of AMD and is protected under U.S. and international copyright
-- and other intellectual property laws.
--
-- DISCLAIMER
-- This disclaimer is not a license and does not grant any
-- rights to the materials distributed herewith. Except as
-- otherwise provided in a valid license issued to you by
-- AMD, and to the maximum extent permitted by applicable
-- law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
-- WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
-- AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
-- BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
-- INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
-- (2) AMD shall not be liable (whether in contract or tort,
-- including negligence, or under any other theory of
-- liability) for any loss or damage of any kind or nature
-- related to, arising under or in connection with these
-- materials, including for any direct, or any indirect,
-- special, incidental, or consequential loss or damage
-- (including loss of data, profits, goodwill, or any type of
-- loss or damage suffered as a result of any action brought
-- by a third party) even if such damage or loss was
-- reasonably foreseeable or AMD had been advised of the
-- possibility of the same.
--
-- CRITICAL APPLICATIONS
-- AMD products are not designed or intended to be fail-
-- safe, or for use in any application requiring fail-safe
-- performance, such as life-support or safety devices or
-- systems, Class III medical devices, nuclear facilities,
-- applications related to the deployment of airbags, or any
-- other applications that could lead to death, personal
-- injury, or severe property or environmental damage
-- (individually and collectively, "Critical
-- Applications"). Customer assumes the sole risk and
-- liability of any use of AMD products in Critical
-- Applications, subject only to applicable laws and
-- regulations governing limitations on product liability.
--
-- THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
-- PART OF THIS FILE AT ALL TIMES.
--
-- DO NOT MODIFY THIS FILE.

-- MODULE VLNV: amd.com:blockdesign:design_1:1.0

-- The following code must appear in the VHDL architecture header.

-- COMP_TAG     ------ Begin cut for COMPONENT Declaration ------
COMPONENT design_1
  PORT (
    DDR3_0_dq : INOUT STD_LOGIC_VECTOR(15 DOWNTO 0);
    DDR3_0_dqs_p : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    DDR3_0_dqs_n : INOUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    DDR3_0_addr : OUT STD_LOGIC_VECTOR(14 DOWNTO 0);
    DDR3_0_ba : OUT STD_LOGIC_VECTOR(2 DOWNTO 0);
    DDR3_0_ras_n : OUT STD_LOGIC;
    DDR3_0_cas_n : OUT STD_LOGIC;
    DDR3_0_we_n : OUT STD_LOGIC;
    DDR3_0_reset_n : OUT STD_LOGIC;
    DDR3_0_ck_p : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
    DDR3_0_ck_n : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
    DDR3_0_cke : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
    DDR3_0_dm : OUT STD_LOGIC_VECTOR(1 DOWNTO 0);
    DDR3_0_odt : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
    eth_rgmii_rd : IN STD_LOGIC_VECTOR(3 DOWNTO 0);
    eth_rgmii_rx_ctl : IN STD_LOGIC;
    eth_rgmii_rxc : IN STD_LOGIC;
    eth_rgmii_td : OUT STD_LOGIC_VECTOR(3 DOWNTO 0);
    eth_rgmii_tx_ctl : OUT STD_LOGIC;
    eth_rgmii_txc : OUT STD_LOGIC;
    eth_mdio_mdc_mdc : OUT STD_LOGIC;
    eth_mdio_mdc_mdio_i : IN STD_LOGIC;
    eth_mdio_mdc_mdio_o : OUT STD_LOGIC;
    eth_mdio_mdc_mdio_t : OUT STD_LOGIC;
    usb_uart_rxd : IN STD_LOGIC;
    usb_uart_txd : OUT STD_LOGIC;
    reset : IN STD_LOGIC;
    phy_reset_out : OUT STD_LOGIC_VECTOR(0 DOWNTO 0);
    sys_clock : IN STD_LOGIC
  );
END COMPONENT;
-- COMP_TAG_END ------  End cut for COMPONENT Declaration  ------

-- The following code must appear in the VHDL architecture
-- body. Substitute your own instance name and net names.

-- INST_TAG     ------ Begin cut for INSTANTIATION Template ------
your_instance_name : design_1
  PORT MAP (
    DDR3_0_dq => DDR3_0_dq,
    DDR3_0_dqs_p => DDR3_0_dqs_p,
    DDR3_0_dqs_n => DDR3_0_dqs_n,
    DDR3_0_addr => DDR3_0_addr,
    DDR3_0_ba => DDR3_0_ba,
    DDR3_0_ras_n => DDR3_0_ras_n,
    DDR3_0_cas_n => DDR3_0_cas_n,
    DDR3_0_we_n => DDR3_0_we_n,
    DDR3_0_reset_n => DDR3_0_reset_n,
    DDR3_0_ck_p => DDR3_0_ck_p,
    DDR3_0_ck_n => DDR3_0_ck_n,
    DDR3_0_cke => DDR3_0_cke,
    DDR3_0_dm => DDR3_0_dm,
    DDR3_0_odt => DDR3_0_odt,
    eth_rgmii_rd => eth_rgmii_rd,
    eth_rgmii_rx_ctl => eth_rgmii_rx_ctl,
    eth_rgmii_rxc => eth_rgmii_rxc,
    eth_rgmii_td => eth_rgmii_td,
    eth_rgmii_tx_ctl => eth_rgmii_tx_ctl,
    eth_rgmii_txc => eth_rgmii_txc,
    eth_mdio_mdc_mdc => eth_mdio_mdc_mdc,
    eth_mdio_mdc_mdio_i => eth_mdio_mdc_mdio_i,
    eth_mdio_mdc_mdio_o => eth_mdio_mdc_mdio_o,
    eth_mdio_mdc_mdio_t => eth_mdio_mdc_mdio_t,
    usb_uart_rxd => usb_uart_rxd,
    usb_uart_txd => usb_uart_txd,
    reset => reset,
    phy_reset_out => phy_reset_out,
    sys_clock => sys_clock
  );
-- INST_TAG_END ------  End cut for INSTANTIATION Template  ------

-- You must compile the wrapper file design_1.vhd when simulating
-- the module, design_1. When compiling the wrapper file, be sure to
-- reference the VHDL simulation library.
