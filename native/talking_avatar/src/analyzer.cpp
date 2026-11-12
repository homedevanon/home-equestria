#include "analyzer.h"
#include <godot_cpp/core/class_db.hpp>
#include <chrono>
#include <stdexcept>
using namespace godot;
namespace {
// Shared immutable weights. Cache is keyed by all model bytes, not just size/path.
std::mutex model_mutex;
std::shared_ptr<const talking_avatar::Model> cached_model;
std::vector<uint8_t> cached_bytes;
std::shared_ptr<const talking_avatar::Model> get_model(const std::vector<uint8_t>& bytes) {
    std::lock_guard<std::mutex> lock(model_mutex);
    if(!cached_model || bytes!=cached_bytes) {auto m=talking_avatar::Model::load(bytes);cached_model=m;cached_bytes=bytes;}
    return cached_model;
}
}
void TalkingAvatarAnalyzer::_bind_methods() {
    ClassDB::bind_method(D_METHOD("begin","model","rate"),&TalkingAvatarAnalyzer::begin);
    ClassDB::bind_method(D_METHOD("push_pcm","pcm"),&TalkingAvatarAnalyzer::push_pcm);
    ClassDB::bind_method(D_METHOD("finish"),&TalkingAvatarAnalyzer::finish);
    ClassDB::bind_method(D_METHOD("cancel"),&TalkingAvatarAnalyzer::cancel);
    ClassDB::bind_method(D_METHOD("poll"),&TalkingAvatarAnalyzer::poll);
    ClassDB::bind_method(D_METHOD("status"),&TalkingAvatarAnalyzer::status);
}
TalkingAvatarAnalyzer::~TalkingAvatarAnalyzer(){cancel();if(worker.joinable())worker.join();}
bool TalkingAvatarAnalyzer::begin(const PackedByteArray& bytes,int rate) {
    std::lock_guard<std::mutex> lock(mutex);
    if(started || rate<8000 || rate>96000 || bytes.size()!=1040276)return false;
    input_rate=rate;
    started=true;
    std::vector<uint8_t> owned(bytes.ptr(),bytes.ptr()+bytes.size());
    worker=std::thread(&TalkingAvatarAnalyzer::run,this,std::move(owned),rate);
    return true;
}
bool TalkingAvatarAnalyzer::push_pcm(const PackedByteArray& bytes) {
    std::lock_guard<std::mutex> lock(mutex);
    if(!started || stopped || eof || !error.empty())return false;
    // Bounded input and total duration match the streaming transport's 60s limit.
    if(bytes.size()%2 || bytes.size()>48000 || pending_frames+bytes.size()/2>size_t(input_rate)*3 || total_frames+bytes.size()/2>size_t(input_rate)*60) {
        error="PCM bounds exceeded";stopped=true;input.clear();pending_frames=0;output.clear();wake.notify_one();return false;
    }
    if(bytes.is_empty())return true;
    std::vector<float> pcm(bytes.size()/2);
    const uint8_t*p=bytes.ptr();for(size_t i=0;i<pcm.size();i++)pcm[i]=int16_t(uint16_t(p[2*i])|uint16_t(p[2*i+1])<<8)/32768.0f;
    pending_frames+=pcm.size();total_frames+=pcm.size();input.push_back(std::move(pcm));wake.notify_one();return true;
}
void TalkingAvatarAnalyzer::finish(){std::lock_guard<std::mutex> lock(mutex);eof=true;wake.notify_one();}
void TalkingAvatarAnalyzer::cancel(){stopped=true;std::lock_guard<std::mutex> lock(mutex);input.clear();output.clear();pending_frames=0;wake.notify_one();}
Array TalkingAvatarAnalyzer::poll(){
    Array result;std::lock_guard<std::mutex> lock(mutex);
    if(stopped)return result;
    for(auto e:output){Dictionary d;d["id"]=e.id;d["time"]=e.seconds;char value[]={talking_avatar::pony_viseme(e.id),0};d["value"]=String(value);result.push_back(d);}
    output.clear();return result;
}
Dictionary TalkingAvatarAnalyzer::status(){std::lock_guard<std::mutex> lock(mutex);Dictionary d;d["error"]=String(error.c_str());d["done"]=done;d["cancelled"]=bool(stopped);d["pending_frames"]=int64_t(pending_frames);d["total_frames"]=int64_t(total_frames);d["processed_frames"]=int64_t(processed_frames);d["compute_ms"]=compute_ms;return d;}
void TalkingAvatarAnalyzer::run(std::vector<uint8_t> bytes,int rate) {
    try {
        auto model=get_model(bytes);
        talking_avatar::Detector detector(model,rate,[this,rate](talking_avatar::Event e){
            std::lock_guard<std::mutex> lock(mutex);
            if(stopped || e.seconds<0 || (eof && e.seconds>=double(total_frames)/rate))return;
            if(output.size()>=512)throw std::runtime_error("Cue queue overflow");
            output.push_back(e);
        });
        while(!stopped) {
            std::vector<float> block;bool flush=false;
            {
                std::unique_lock<std::mutex> lock(mutex);wake.wait(lock,[this]{return stopped||!input.empty()||eof;});
                if(stopped)break;
                if(input.empty()){flush=eof;}else{block=std::move(input.front());input.pop_front();pending_frames-=block.size();}
            }
            auto start=std::chrono::steady_clock::now();
            if(flush)detector.finish();
            else for(size_t i=0;i<block.size() && !stopped;i+=1920)detector.push(block.data()+i,std::min(size_t(1920),block.size()-i));
            {std::lock_guard<std::mutex> lock(mutex);processed_frames+=block.size();compute_ms+=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();}
            if(flush)break;
        }
    }catch(const std::exception&e){std::lock_guard<std::mutex> lock(mutex);error=e.what();output.clear();input.clear();pending_frames=0;stopped=true;}
    std::lock_guard<std::mutex> lock(mutex);done=true;
}
