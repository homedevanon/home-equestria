// Port of Talking Avatar's MIT-licensed inference, resampler, and detector.
// Copyright (c) 2026 InterviewFlowAI. See ../LICENSE.talking-avatar.
#pragma once
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace talking_avatar {
struct Event { int id; double seconds; };
struct Model {
    std::map<std::string, std::vector<float>> tensors;
    static std::shared_ptr<const Model> load(const std::vector<uint8_t> &bytes);
};
class Resampler {
    double step, pos;
    int half;
    std::vector<std::vector<float>> kernels;
    std::vector<float> input;
public:
    explicit Resampler(int input_rate);
    std::vector<float> push(const float *samples, size_t count);
};
class Stream {
    std::shared_ptr<const Model> model;
    std::vector<float> window, filters, frame, mel, x, y, logits;
    std::vector<double> re, im;
    std::vector<std::vector<std::vector<float>>> history;
    int filled = 0, since_hop = 0;
    int step();
public:
    explicit Stream(std::shared_ptr<const Model> m);
    void push(const float *samples, size_t count, const std::function<void(int)> &on_frame);
};
class Detector {
    Resampler resampler;
    Stream stream;
    int input_rate, frames = 0, last = -1, candidate = -1, candidate_run = 0;
    bool finished = false;
    std::function<void(Event)> callback;
    void on_frame(int id);
    void feed(const float *samples, size_t count);
public:
    Detector(std::shared_ptr<const Model> model, int rate, std::function<void(Event)> cb);
    void push(const float *samples, size_t count);
    void finish();
};
char pony_viseme(int id);
}
