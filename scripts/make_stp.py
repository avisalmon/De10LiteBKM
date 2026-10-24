"""Write a Signal Tap file (.stp) without the GUI.

  python make_stp.py <out.stp> <clock node> <trigger> <depth> <node> [<node> ...]

  <trigger>  "<node>:<rising|falling|high|low>" or "none" (trigger at once)
  <node>     full Quartus node name, e.g. "debug_link:debug|tx_valid"; a bus as "name[11:0]"

Then:  quartus_stp <rev> --stp_file <out.stp> --enable  ->  recompile  ->  program
       quartus_stp -t stp_capture.tcl <out.stp> <out.vcd>
Instance "auto_signaltap_0", signal set "signal_set: 1", trigger "trigger: 1".
Format follows the .stp files Quartus writes (session > instance > signal_set > trigger).
"""
import os
import re
import sys
from xml.sax.saxutils import quoteattr

EDGE = {"rising": "rising edge", "falling": "falling edge", "high": "high", "low": "low"}
# as jtagconfig names them; override with STP_CABLE / STP_DEVICE / STP_SOF
CABLE = os.environ.get("STP_CABLE", "USB-Blaster [USB-0]")
DEVICE = os.environ.get("STP_DEVICE", "@1: 10M50DA(.|ES)/10M50DC (0x031050DD)")
SOF = os.environ.get("STP_SOF", "output_files/hello.sof")


def expand(node):
    m = re.match(r"^(.*)\[(\d+):(\d+)\]$", node)
    if not m:
        return [node]
    base, hi, lo = m.group(1), int(m.group(2)), int(m.group(3))
    return [f"{base}[{i}]" for i in range(lo, hi + 1)]


def make(clock, trigger, depth, nodes):
    wires = [w for n in nodes for w in expand(n)]
    wire_xml = "\n".join(f'          <wire name={quoteattr(w)} tap_mode="classic" type="unknown"/>' for w in wires)
    nets = "\n".join(
        f'          <net data_index="{i}" is_data_input="true" is_node_valid="true" is_selected="false" '
        f'is_storage_input="true" is_trigger_input="true" name={quoteattr(w)} storage_index="{i}" '
        f'tap_mode="classic" trigger_index="{i}" type="unknown"/>' for i, w in enumerate(wires))
    if trigger == "none":
        cond = ""
    else:
        tnode, kind = trigger.rsplit(":", 1)
        cond = f"'{tnode}' == {EDGE[kind]}"
    ones = "1" * len(wires)
    # without the cable and device the run "succeeds" with no data and the export crashes
    return f"""<session jtag_chain={quoteattr(CABLE)} jtag_device={quoteattr(DEVICE)} sof_file={quoteattr(SOF)} top_level_entity="hello_top">
  <display_tree gui_logging_enabled="0">
    <display_branch instance="auto_signaltap_0" signal_set="USE_GLOBAL_TEMP" trigger="USE_GLOBAL_TEMP"/>
  </display_tree>
  <instance enabled="true" entity_name="sld_signaltap" is_auto_node="yes" is_expanded="true" name="auto_signaltap_0" source_file="sld_signaltap.vhd">
    <node_ip_info instance_id="0" mfg_id="110" node_id="0" version="6"/>
    <signal_set global_temp="1" is_expanded="true" name="signal_set: 1">
      <clock name={quoteattr(clock)} polarity="posedge" tap_mode="classic"/>
      <config ram_type="AUTO" reserved_data_nodes="0" reserved_storage_qualifier_nodes="0" reserved_trigger_nodes="0" sample_depth="{depth}" trigger_in_enable="no" trigger_out_enable="no"/>
      <top_entity/>
      <signal_vec>
        <trigger_input_vec>
{wire_xml}
        </trigger_input_vec>
        <data_input_vec>
{wire_xml}
        </data_input_vec>
        <storage_qualifier_input_vec>
{wire_xml}
        </storage_qualifier_input_vec>
      </signal_vec>
      <presentation>
        <data_view>
{nets}
        </data_view>
        <setup_view>
{nets}
        </setup_view>
        <trigger_in_editor/>
        <trigger_out_editor/>
      </presentation>
      <trigger attribute_mem_mode="false" gap_record="true" global_temp="1" name="trigger: 1" position="pre" power_up_trigger_mode="false" record_data_gap="true" segment_size="{depth}" storage_mode="off" storage_qualifier_disabled="no" storage_qualifier_port_is_pin="true" storage_qualifier_port_name="auto_stp_external_storage_qualifier" storage_qualifier_port_tap_mode="classic" trigger_type="circular">
        <power_up_trigger position="pre" storage_qualifier_disabled="no"/>
        <events use_custom_flow_control="no">
          <level enabled="yes" name="condition1" type="basic">{cond}
            <power_up enabled="yes">
            </power_up>
            <op_node/>
          </level>
        </events>
        <storage_qualifier_events>
          <transitional>{ones}
            <pwr_up_transitional>{ones}</pwr_up_transitional>
          </transitional>
          <storage_qualifier_level type="basic">
            <power_up>
            </power_up>
            <op_node/>
          </storage_qualifier_level>
        </storage_qualifier_events>
      </trigger>
    </signal_set>
  </instance>
  <mnemonics/>
</session>
"""


if __name__ == "__main__":
    if len(sys.argv) < 6:
        sys.exit(__doc__)
    out, clock, trigger, depth = sys.argv[1:5]
    with open(out, "w", newline="\n") as f:
        f.write(make(clock, trigger, int(depth), sys.argv[5:]))
    print(f"wrote {out}")
