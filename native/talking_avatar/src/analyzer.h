#pragma once
#include "core.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

class TalkingAvatarAnalyzer : public godot::RefCounted {
    GDCLASS(TalkingAvatarAnalyzer, godot::RefCounted)
    std::thread worker;
    std::atomic<bool> stopped{false};
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<std::vector<float>> input;
    std::deque<talking_avatar::Event> output;
    size_t pending_frames=0, total_frames=0;
    size_t processed_frames=0;
    int input_rate=24000;
    bool eof=false, done=false, started=false;
    std::string error;
    double compute_ms=0;
    void run(std::vector<uint8_t> bytes, int rate);
protected:
    static void _bind_methods();
public:
    ~TalkingAvatarAnalyzer();
    bool begin(const godot::PackedByteArray &bytes, int rate);
    bool push_pcm(const godot::PackedByteArray &bytes);
    void finish();
    void cancel();
    godot::Array poll();
    godot::Dictionary status();
};
