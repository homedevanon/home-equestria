// Numerical semantics follow upstream JS: double arithmetic, float32 storage.
// Disable floating-point contraction/fast-math when building this translation unit.
#include "core.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>

namespace talking_avatar {
static constexpr double PI = 3.14159265358979323846;
static const int DILATIONS[] = {1,2,4,8,16};
static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }

std::shared_ptr<const Model> Model::load(const std::vector<uint8_t> &bytes) {
    require(bytes.size() == 1040276, "Unexpected model size");
    uint32_t n = uint32_t(bytes[0]) | uint32_t(bytes[1])<<8 | uint32_t(bytes[2])<<16 | uint32_t(bytes[3])<<24;
    require(n < 65536 && n + 4 < bytes.size(), "Invalid model header");
    auto h = nlohmann::json::parse(bytes.begin()+4, bytes.begin()+4+n);
    for (auto [key,value] : std::map<std::string,int>{{"SR",16000},{"WIN",400},{"HOP",160},{"NFFT",512},{"N_MELS",80},{"channels",128},{"kernel",3},{"lookahead",2},{"classes",22}})
        require(h.at(key) == value, "Unsupported model architecture");
    require(h.at("dilations") == std::vector<int>({1,2,4,8,16}), "Unsupported dilations");
    require(h.at("FMIN")==20.0 && h.at("FMAX")==8000.0 && h.at("LOG_FLOOR")==1e-6, "Unsupported feature configuration");
    std::map<std::string,std::vector<int>> expected = {{"mean",{80}},{"std",{80}}, {"inp.bias",{128}},{"inp.weight",{128,80,1}}, {"out.bias",{22}},{"out.weight",{22,128,1}}};
    for (int i=0;i<5;i++) {expected["blocks."+std::to_string(i)+".bias"]={128};expected["blocks."+std::to_string(i)+".weight"]={128,128,3};}
    auto model = std::make_shared<Model>();
    for (const auto &t : h.at("tensors")) {
        const auto name=t.at("name").get<std::string>();
        require(expected.count(name) && !model->tensors.count(name), "Unexpected/duplicate tensor");
        require(t.at("shape") == expected.at(name), "Invalid tensor shape");
        size_t count=1; for (int dim:expected.at(name)) count*=dim;
        const size_t offset=t.at("offset").get<size_t>();
        require(offset <= bytes.size()/4 && count <= bytes.size()/4-offset && 4+n+(offset+count)*4 <= bytes.size(), "Tensor out of bounds");
        auto &v=model->tensors[name]; v.resize(count);
        for (size_t i=0;i<count;i++) {
            const auto *p=bytes.data()+4+n+(offset+i)*4;
            uint32_t bits=uint32_t(p[0])|uint32_t(p[1])<<8|uint32_t(p[2])<<16|uint32_t(p[3])<<24;
            std::memcpy(&v[i],&bits,4); require(std::isfinite(v[i]), "Nonfinite model weight");
        }
    }
    require(model->tensors.size()==expected.size(), "Missing tensor");
    for (float v:model->tensors.at("std")) require(v>0,"Invalid feature normalization");
    return model;
}

Resampler::Resampler(int rate) : step(double(rate)/16000),pos(0),half(0) {
    require(rate>=8000 && rate<=96000,"Unsupported input rate");
    const double cutoff=(.9*std::min(rate,16000))/2/rate;
    half=int(std::ceil(12/(2*cutoff)));
    for(int p=0;p<128;p++) {
        std::vector<float> kernel(2*half);
        for(int i=0;i<2*half;i++) {
            const double d=i-half+1-double(p)/128, x=2*cutoff*d;
            const double sinc=x==0?1:std::sin(PI*x)/(PI*x);
            const double w=.42+.5*std::cos(PI*d/half)+.08*std::cos(2*PI*d/half);
            kernel[i]=float(2*cutoff*sinc*w);
        }
        kernels.push_back(std::move(kernel));
    }
    input.resize(half-1); pos=half-1;
}
std::vector<float> Resampler::push(const float *samples,size_t count) {
    if(count) input.insert(input.end(),samples,samples+count);
    std::vector<float> output;
    for(;;) {
        int base=int(std::floor(pos)),phase=int(std::floor((pos-base)*128+.5));
        if(phase==128) {base++;phase=0;}
        if(base+half>=int(input.size())) break;
        double sum=0;
        for(size_t i=0;i<kernels[phase].size();i++) sum+=double(kernels[phase][i])*input[base-half+1+i];
        output.push_back(float(sum)); pos+=step;
    }
    const int keep=std::max(0,int(std::floor(pos))-half+1);
    input.erase(input.begin(),input.begin()+keep); pos-=keep;
    return output;
}

static void fft(std::vector<double>&re,std::vector<double>&im) {
    const int n=int(re.size());
    for(int i=1,j=0;i<n;i++) {
        int bit=n>>1;for(;j&bit;bit>>=1) j^=bit; j^=bit;
        if(i<j){std::swap(re[i],re[j]);std::swap(im[i],im[j]);}
    }
    for(int len=2;len<=n;len<<=1) {
        const double ang=-2*PI/len;const int half=len/2;
        for(int i=0;i<n;i+=len) for(int k=0;k<half;k++) {
            const double wr=std::cos(ang*k), wi=std::sin(ang*k);
            const double vr=re[i+k+half]*wr-im[i+k+half]*wi, vi=re[i+k+half]*wi+im[i+k+half]*wr;
            re[i+k+half]=re[i+k]-vr;im[i+k+half]=im[i+k]-vi;re[i+k]+=vr;im[i+k]+=vi;
        }
    }
}
static void mat_add(std::vector<float>&y,const std::vector<float>&w,const std::vector<float>&x,int outs,int ins,int kernel,int tap) {
    for(int o=0;o<outs;o++) {
        double sum=0;const int row=o*ins*kernel+tap;
        for(int i=0;i<ins;i++) sum+=double(w[row+i*kernel])*x[i];
        y[o]=float(double(y[o])+sum);
    }
}
Stream::Stream(std::shared_ptr<const Model> m) : model(std::move(m)),window(400),filters(80*257),frame(400),mel(80),x(128),y(128),logits(22),re(512),im(512) {
    for(int i=0;i<400;i++) window[i]=float(.5-.5*std::cos(2*PI*i/400));
    const auto to_mel=[](double f){return 2595*std::log10(1+f/700);};
    const double step=(to_mel(8000)-to_mel(20))/81;
    double edges[82];for(int i=0;i<82;i++)edges[i]=700*(std::pow(10,(to_mel(20)+step*i)/2595)-1);
    for(int m=0;m<80;m++)for(int k=0;k<257;k++){
        const double hz=k*16000.0/512;
        filters[m*257+k]=float(std::max(0.0,std::min((hz-edges[m])/(edges[m+1]-edges[m]),(edges[m+2]-hz)/(edges[m+2]-edges[m+1]))));
    }
    for(int d:DILATIONS)history.emplace_back(2*d+1,std::vector<float>(128));
}
void Stream::push(const float *samples,size_t count,const std::function<void(int)>&cb) {
    for(size_t i=0;i<count;i++) {
        std::move(frame.begin()+1,frame.end(),frame.begin());frame.back()=samples[i];
        filled=std::min(400,filled+1);since_hop++;
        if(filled==400 && since_hop>=160){since_hop=0;cb(step());}
    }
}
int Stream::step() {
    const auto&t=model->tensors;
    std::fill(re.begin(),re.end(),0);std::fill(im.begin(),im.end(),0);
    for(int n=0;n<400;n++) re[n]=double(frame[n])*window[n];
    fft(re,im);
    for(int m=0;m<80;m++) {
        double sum=0;for(int k=0;k<257;k++)sum+=double(filters[m*257+k])*(re[k]*re[k]+im[k]*im[k]);
        mel[m]=float((std::log(sum+1e-6)-t.at("mean")[m])/t.at("std")[m]);
    }
    x=t.at("inp.bias");mat_add(x,t.at("inp.weight"),mel,128,80,1,0);
    for(int l=0;l<5;l++) {
        auto&hist=history[l];std::rotate(hist.begin(),hist.begin()+1,hist.end());hist.back()=x;
        const auto prefix="blocks."+std::to_string(l);
        y=t.at(prefix+".bias");
        for(int k=0;k<3;k++) mat_add(y,t.at(prefix+".weight"),hist[hist.size()-1-(2-k)*DILATIONS[l]],128,128,3,k);
        for(int c=0;c<128;c++)y[c]=float(double(x[c])+std::max(0.0,double(y[c])));
        x.swap(y);
    }
    logits=t.at("out.bias");mat_add(logits,t.at("out.weight"),x,22,128,1,0);
    return int(std::max_element(logits.begin(),logits.end())-logits.begin());
}
Detector::Detector(std::shared_ptr<const Model> m,int rate,std::function<void(Event)>cb):resampler(rate),stream(std::move(m)),input_rate(rate),callback(std::move(cb)){}
void Detector::on_frame(int id) {
    frames++;if(frames<=2)return;
    candidate_run=id==candidate?candidate_run+1:1;candidate=id;
    if(id==last || (candidate_run<2 && !(id==21 && last==0)))return;
    last=id;const int first=frames-candidate_run;
    callback({id,((first-2)*160+200)/16000.0});
}
void Detector::feed(const float*samples,size_t count){auto out=resampler.push(samples,count);stream.push(out.data(),out.size(),[this](int id){on_frame(id);});}
void Detector::push(const float*samples,size_t count){require(!finished,"Push after EOF");feed(samples,count);}
void Detector::finish(){if(finished)return;finished=true;std::vector<float> zeros(size_t(std::ceil(1040.0*input_rate/16000))+64);feed(zeros.data(),zeros.size());}
char pony_viseme(int id){static const char values[]={'X','C','D','E','C','E','B','F','F','D','E','D','B','E','H','B','B','B','G','B','B','A'};return id>=0&&id<22?values[id]:'X';}
}
