#!/bin/sh
export $(grep -v '^#' .env | xargs -d '\n') && zig build run
