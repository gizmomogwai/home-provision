#!/bin/sh -x
sudo ip netns exec protected su -l pi -c /usr/bin/deluged || true
