# rtchart

<video src="https://github.com/user-attachments/assets/0af8447b-ffcd-4fe7-91e4-86b1d565a93f" autoplay loop muted playsinline width="390" align="right"></video>

[`rtchart`](https://rtchart.cloud.esseforma.com) is a WebRTC room for publishing ad hoc realtime candlestick chart data.
It is intended for quickly sending live numeric streams into a browser-visible
chart without building a custom dashboard first.

This repository describes rtchart capabilities and hosts open source feeders.
Feeders are small programs that collect or derive measurements over time and
push those values to the `rtchart` CLI.

Use this repository to file issues with rtchart or its feeders, propose feeder
ideas, and hold general discussion about rtchart use cases and behavior.

<br clear="right">

## Example feeder: Linux load

<video src="https://github.com/user-attachments/assets/3e80723a-8c87-4cd3-8802-1479fa10bec8" autoplay loop muted playsinline width="390" align="right"></video>

The `linux_load.sh` feeder samples the kernel's per-CPU runqueue
counters and 1-minute load-average EWMA at 100 ms cadence, then drives up
to three rtchart instances with the resulting streams (runnable tasks,
uninterruptible tasks, and the load1 average).

<br clear="right">
