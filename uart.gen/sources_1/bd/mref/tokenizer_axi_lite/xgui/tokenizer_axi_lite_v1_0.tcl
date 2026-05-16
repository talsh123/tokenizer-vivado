# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "CHAR_W" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "IN_FIFO_DEPTH_LOG2" -parent ${Page_0}
  ipgui::add_param $IPINST -name "OUT_FIFO_DEPTH_LOG2" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TOKEN_W" -parent ${Page_0}


}

proc update_PARAM_VALUE.CHAR_W { PARAM_VALUE.CHAR_W } {
	# Procedure called to update CHAR_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.CHAR_W { PARAM_VALUE.CHAR_W } {
	# Procedure called to validate CHAR_W
	return true
}

proc update_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to update C_S_AXI_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to validate C_S_AXI_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to update C_S_AXI_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_DATA_WIDTH { PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to validate C_S_AXI_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.IN_FIFO_DEPTH_LOG2 { PARAM_VALUE.IN_FIFO_DEPTH_LOG2 } {
	# Procedure called to update IN_FIFO_DEPTH_LOG2 when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.IN_FIFO_DEPTH_LOG2 { PARAM_VALUE.IN_FIFO_DEPTH_LOG2 } {
	# Procedure called to validate IN_FIFO_DEPTH_LOG2
	return true
}

proc update_PARAM_VALUE.OUT_FIFO_DEPTH_LOG2 { PARAM_VALUE.OUT_FIFO_DEPTH_LOG2 } {
	# Procedure called to update OUT_FIFO_DEPTH_LOG2 when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.OUT_FIFO_DEPTH_LOG2 { PARAM_VALUE.OUT_FIFO_DEPTH_LOG2 } {
	# Procedure called to validate OUT_FIFO_DEPTH_LOG2
	return true
}

proc update_PARAM_VALUE.TOKEN_W { PARAM_VALUE.TOKEN_W } {
	# Procedure called to update TOKEN_W when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TOKEN_W { PARAM_VALUE.TOKEN_W } {
	# Procedure called to validate TOKEN_W
	return true
}


proc update_MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH PARAM_VALUE.C_S_AXI_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH PARAM_VALUE.C_S_AXI_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.CHAR_W { MODELPARAM_VALUE.CHAR_W PARAM_VALUE.CHAR_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.CHAR_W}] ${MODELPARAM_VALUE.CHAR_W}
}

proc update_MODELPARAM_VALUE.TOKEN_W { MODELPARAM_VALUE.TOKEN_W PARAM_VALUE.TOKEN_W } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TOKEN_W}] ${MODELPARAM_VALUE.TOKEN_W}
}

proc update_MODELPARAM_VALUE.IN_FIFO_DEPTH_LOG2 { MODELPARAM_VALUE.IN_FIFO_DEPTH_LOG2 PARAM_VALUE.IN_FIFO_DEPTH_LOG2 } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.IN_FIFO_DEPTH_LOG2}] ${MODELPARAM_VALUE.IN_FIFO_DEPTH_LOG2}
}

proc update_MODELPARAM_VALUE.OUT_FIFO_DEPTH_LOG2 { MODELPARAM_VALUE.OUT_FIFO_DEPTH_LOG2 PARAM_VALUE.OUT_FIFO_DEPTH_LOG2 } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.OUT_FIFO_DEPTH_LOG2}] ${MODELPARAM_VALUE.OUT_FIFO_DEPTH_LOG2}
}

