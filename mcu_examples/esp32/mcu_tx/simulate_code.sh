#!/bin/bash
idf.py build qemu --qemu-extra-args="-trace events=trace_events.txt,file=qemu_gpio_trace.log"
