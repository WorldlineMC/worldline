# M1 packet classification v0

**Status:** Experimental notes for the disposable M1 spike.

| Traffic | M1 handling |
| --- | --- |
| Backend login handshake and authentication | Proxy-owned for both connections |
| Destination configuration start/finish | Proxy-owned; acknowledged to the destination only |
| Destination registries, tags, links, reports, brand | Withheld; the harness requires identical backends |
| Destination configuration keepalive | Proxy-owned and echoed to the destination |
| Destination `ClientboundLoginPacket` | Withheld; used as the splice-ready marker |
| Destination initial difficulty, abilities, recipes, scoreboard, teleport, level info, effects | Withheld by the Paper resume placement path |
| Serverbound play packets after the splice | Forwarded to the destination |
| Clientbound play packets after the splice | Forwarded from the destination |
| Source traffic after the splice | Rejected by closing the source connection |

The spike does not translate entity IDs, teleport IDs, signed-chat state, or tick state. It only
tests the standing-player connection splice against identical world, registry, dimension, and view
settings. Those translations remain required before this code can graduate into M5.
