// The in-game network of CoopSync (2026-10-25): what CoopNet.exe did, inside the game process. A worker thread runs
// the Steam lobby + SteamNetworkingMessages (through the game's own steam_api64.dll, flat API, no SDK headers) or the
// local test link (TCP on 127.0.0.1, two games on one PC). The Lua side talks to it through memory (net.hpp's calls,
// registered as CoopNative_Net* in dllmain.cpp) instead of the channel files:
//   lines   state channel 0 (host.events / client.requests), fast channel 1 (host.fast / client.fast)
//   menu    command(): create | join <lobby> | leave | invite <steamid> | mode foot|car | ready 0|1 | start | runend
//           status(): CoopNet's net-status.txt text (also written to <chan>/net-status.txt for tests and reports)
//   session session_lines(): role host | role client | mode <m> | go | stop  (what CoopNet wrote into control.txt)
// Documents (the host's zone list, run descriptor, gates, map, session line) go through memory too (doc_put /
// doc_get; Lua names them "doc:<name>", link.lua); no files on disk carry anything between the players.
#pragma once
#include <string>

namespace coopnet
{
    // spec: "" = Steam, "tcp:<port>:<name>" = the local test link. Again with the same channel: nothing (the Lua mod
    // restarted, the network keeps running).
    std::string start(const std::string& chan, const std::string& spec);
    void stop();
    void command(const std::string& line);
    std::string session_lines();          // lines since the last call, each ending in "\n"
    std::string status();
    void send_line(int ch, const std::string& line);
    std::string recv_lines(int ch);       // complete lines since the last call, each ending in "\n"
    void drain(int ch);                   // forget what came in on ch (a session start: older lines belong to the last one)
    // documents: the host's zone list, run descriptor, gates, map, session line - its latest version of each goes to the
    // peer (and again to every new peer); the guest reads the latest it got (version: how many it got of that name)
    void doc_put(const std::string& name, const std::string& data);
    bool doc_get(const std::string& name, std::string& data, int64_t& version);
} // namespace coopnet
