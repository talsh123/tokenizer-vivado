---
name: vitis-bsp-phy-patches
description: Custom RTL8211E PHY patches in the Vitis BSP that get wiped on .xsa re-read/BSP regen and must be restored
metadata: 
  node_type: memory
  type: project
  originSessionId: 16b7024a-33c1-4f84-bdc8-3257672d4551
---

The Vitis project `C:\Users\talsh\Vitis\final_project_eth_nexys_video` has two hand-edited BSP files (marked `/// ------------------------ MY CODE ------------------------` … `END OF MY CODE`) that add RTL8211E PHY support for the Nexys Video board. The stock Xilinx lwIP BSP does **not** handle this PHY. **Regenerating the bitstream in Vivado and re-reading the `.xsa` in Vitis overwrites the BSP and DELETES these edits — they must be re-applied after every such regen.** (The `echo.c` app under `lwip_echo_server/src/` is app code, not BSP, and is NOT wiped.)

**Why:** the RTL8211E's auto-negotiation is unreliable with the stock BSP — repeated re-negotiation sometimes drops to 10 Mbps or fails; and `get_IEEE_phy_speed` doesn't recognize the Realtek OUI at all.

Both files live in:
`...\bsp\libsrc\lwip220\src\lwip-2.2.0\contrib\ports\xilinx\netif\`

### Patch 1 — `xadapter.c`, in `axieth_link_status`'s `ETH_LINK_NEGOTIATING` case
Replaces the stock case: full PHY setup only on the **first** link-up; on any later link-down/up, skip auto-neg and hardcode 100 Mbps (`static int first_link` persists across calls).
```c
        case ETH_LINK_NEGOTIATING:
            if (phy_link_status && phy_autoneg_status) {

                static int first_link = 1;
                if (first_link) {
                    link_speed = phy_setup_axiemac(xemacp);
                    first_link = 0;
                } else {
                    link_speed = 100;
                }
                XAxiEthernet_SetOperatingSpeed(xemacp,link_speed);
                netif_set_link_up(netif);
                xemacs->eth_link_status = ETH_LINK_UP;
                xil_printf("Ethernet Link up\r\n");
            }
            break;
```

### Patch 2 — `xaxiemacif_physpeed.c`, in `get_IEEE_phy_speed`, an `else if` branch added before the final `else` (after the TI DP83867 block)
Recognizes Realtek OUI `0x001c` and reads the negotiated speed from the RTL8211E PHYSR (page 0, register 0x1A, bits [5:4]).
```c
    else if (phy_identifier == 0x001c) { // check for Realtek's IEEE OUI (Organizationally Unique Identifier)
        u16 status;
        u16 speed;

        // 0x1F is the page select register on the RTL8211E. write 0x0000 -> page 0.
        XAxiEthernet_PhyWrite(xaxiemacp, phy_addr, 0x1f, 0x0000);
        // 0x1A on page 0 is the RTL8211E PHY-Specific Status Register (PHYSR) with negotiated speed.
        XAxiEthernet_PhyRead(xaxiemacp, phy_addr, 0x1A, &status);
        // bits [5:4]: 00=10, 01=100, 10=1000 Mbps
        speed = (status >> 4) & 0x03;

        if (speed == 2) {
            xil_printf("RTL8211E: Negotiated speed 1000 Mbps\r\n");
            return 1000;
        } else if (speed == 1) {
            xil_printf("RTL8211E: Negotiated speed 100 Mbps\r\n");
            return 100;
        } else {
            xil_printf("RTL8211E: Negotiated speed 10 Mbps\r\n");
            return 10;
        }
    }
```

Related: the M3/M4 `echo.c` firmware work uses STATUS bit 3 (`pipeline_busy`) — see [[wordpiece-tokenizer-status]] if present.
