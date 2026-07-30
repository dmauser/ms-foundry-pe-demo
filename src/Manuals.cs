// Scenario 2 sample data — fictional appliance product manuals.
//
// These are uploaded (from inside the VNet, by /api/seed) to the PRIVATE blob
// storage / File Search vector store and become the agent's grounding corpus.
// They are intentionally small and self-contained; the error-code tables (E1..E6)
// are what the "why is my washer showing error E4?" demo query grounds against.
static class Manuals
{
    public static readonly (string FileName, string Content)[] All =
    [
        ("AquaWash-3000-Washer-Manual.md", AquaWash),
        ("DryMaster-500-Dryer-Manual.md", DryMaster),
        ("SparkleClean-200-Dishwasher-Manual.md", SparkleClean),
    ];

    private const string AquaWash = """
# AquaWash 3000 Front-Load Washer — Owner's Manual

## Overview
The AquaWash 3000 is a 4.5 cu. ft. front-load washing machine with 12 wash
cycles and an inverter direct-drive motor. Model number: AW-3000. This manual
covers installation, operation, maintenance, and troubleshooting.

## Error Codes
| Code | Meaning | Recommended Action |
|------|---------|--------------------|
| E1 | Water not filling | Check that both water supply taps are open and the inlet hoses are not kinked. Clean the inlet filter screens. |
| E2 | Water not draining | Clean the drain pump filter behind the lower front panel. Make sure the drain hose is no higher than 39 inches and is not clogged. |
| E3 | Door lock fault | Ensure the door is fully closed. If the code persists, the door interlock switch may need service. |
| E4 | Excessive suds / oversudsing detected | The machine detected too many suds, which prevents proper draining and spinning. Use only HE (High-Efficiency) detergent and reduce the detergent amount to one tablespoon. Run the "Drain & Spin" cycle to clear the suds, then restart. Persistent E4 usually means too much detergent or non-HE detergent was used. |
| E5 | Unbalanced load | Redistribute the laundry evenly around the drum. Wash bulky items with smaller items to balance the spin. |
| E6 | Motor overheat protection | Turn the washer off for 30 minutes to let the motor cool, then resume. |

## Error E4 in Detail
Error **E4** indicates **oversudsing**. During the spin phase the AquaWash 3000
monitors suds levels; when foam is excessive the drum cannot reach spin speed and
the cycle pauses to protect the bearings. To resolve E4:
1. Cancel the current cycle and select **Drain & Spin**.
2. Switch to **HE detergent** and use no more than **1 tablespoon** per load.
3. If foam remains, run an extra **Rinse & Spin** with no detergent.

Recurrent E4 across multiple loads points to detergent type/quantity, not a
hardware fault.

## Maintenance
Run the **Tub Clean** cycle monthly. Leave the door ajar between washes to
prevent odor. Clean the drain pump filter every 3 months.
""";

    private const string DryMaster = """
# DryMaster 500 Electric Dryer — Owner's Manual

## Overview
The DryMaster 500 is a 7.4 cu. ft. electric vented dryer with moisture sensing
and 10 dry cycles. Model number: DM-500.

## Error Codes
| Code | Meaning | Recommended Action |
|------|---------|--------------------|
| F1 | Airflow restricted | Clean the lint filter before every load. Inspect and clear the exhaust vent duct. |
| F2 | Heating element fault | Unplug for 10 minutes. If heat does not return, the element requires service. |
| F3 | Moisture sensor dirty | Wipe the metal moisture-sensor bars inside the drum with a soft cloth. |
| F4 | Thermal fuse tripped | Caused by blocked venting; clear the vent and reset. Repeated F4 needs a technician. |

## Drying Tips
Clean the lint screen every load. A clogged vent is the #1 cause of long dry
times and F1/F4 errors. Do not overload — clothes need room to tumble.
""";

    private const string SparkleClean = """
# SparkleClean 200 Dishwasher — Owner's Manual

## Overview
The SparkleClean 200 is a 24-inch built-in dishwasher with a stainless tub and
6 wash cycles. Model number: SC-200.

## Error Codes
| Code | Meaning | Recommended Action |
|------|---------|--------------------|
| C1 | Water inlet problem | Confirm the water supply valve is open and the inlet screen is clean. |
| C2 | Drain fault | Clear the drain filter at the bottom of the tub and check the disposal air gap. |
| C3 | Leak detected | The base pan float has risen. Turn off the water and check the door gasket and hose connections. |
| C4 | Heating fault | The heating element is not reaching temperature; dishes may be wet. Service may be required. |

## Loading & Detergent
Use rinse aid for spot-free drying. Do not block the spray arms with tall items.
Scrape—but do not pre-rinse—dishes for best sensor performance.
""";
}
