#include "pony_ponese_voice.h"

#include "world/codec.h"
#include "world/synthesis.h"

#include <godot_cpp/classes/json.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/char_string.hpp>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstring>

namespace godot {

namespace {

constexpr int RATE = 24000;
constexpr double FRAME_MS = 5.0;
constexpr double STYLE = .5; // how much of her own melody, pace and loudness (A4)
constexpr int CANDIDATES = 12;
constexpr double MAX_SECONDS = 45.0;
constexpr double PI = 3.14159265358979323846;

// Vowel ids in bank order (manifest "vowels").
enum { IY, EH, AE, EY, AA, AH, AY, AR, OW, ER, UW, YU, VOWELS };
const char *const MOUTH[VOWELS] = { "B", "C", "C", "C", "D", "D", "D", "D", "E", "E", "F", "F" };
const std::vector<int> FALLBACK[VOWELS] = {
	{ EH, ER }, { AE, IY }, { EH, AA }, { EH, IY }, { AH, AE, AR }, { AA, ER },
	{ AA, AH }, { AA, AH }, { UW, AH }, { AH, EH }, { YU, OW, ER }, { UW, OW },
};

uint32_t text_hash(const std::string &p_text) {
	uint32_t h = 2166136261u;
	for (unsigned char c : p_text) {
		h = (h ^ c) * 16777619u;
	}
	return h;
}

// ---------------------------------------------------------------- spelling (same rules as the game)

int group_vowel(const std::string &p_group, bool p_at_end) {
	const bool r = !p_group.empty() && p_group.back() == 'r';
	const std::string body = r ? p_group.substr(0, p_group.size() - 1) : p_group;
	if (r && body == "a") {
		return AR;
	}
	if (r && (body == "e" || body == "i" || body == "u" || body == "ea" || body == "ou")) {
		return ER;
	}
	if (body == "ee" || body == "ea" || body == "ie" || body == "ei" || body == "ey") {
		return IY;
	}
	if (body == "ai" || body == "ay") {
		return EY;
	}
	if (body == "oo" || body == "ew" || body == "ue" || body == "ui") {
		return UW;
	}
	if (body == "oa" || body == "oe" || body == "ow") {
		return OW;
	}
	if (body == "oi" || body == "oy") {
		return AY;
	}
	if (body == "ou") {
		return p_at_end ? UW : AA;
	}
	if (body == "y") {
		return p_at_end ? IY : AY;
	}
	if (body == "a") {
		return p_at_end ? EY : AE;
	}
	if (body == "e") {
		return p_at_end ? IY : EH;
	}
	if (body == "i") {
		return p_at_end ? AY : EH;
	}
	if (body == "o") {
		return p_at_end ? OW : AA;
	}
	if (body == "u") {
		return p_at_end ? UW : AH;
	}
	return AH;
}

bool is_vowel_letter(char c) {
	return c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u' || c == 'y';
}

// Vowel class of each spelled syllable ("tree" -> IY, "go" -> OW), at most seven.
std::vector<int> spelled_vowels(const std::string &p_word) {
	std::string lower;
	for (char c : p_word) {
		if (c >= 'A' && c <= 'Z') {
			c = char(c - 'A' + 'a');
		}
		if (c >= 'a' && c <= 'z') {
			lower += c;
		}
	}
	struct Group {
		std::string text;
		size_t start, end;
	};
	std::vector<Group> groups;
	for (size_t i = 0; i < lower.size();) {
		if (!is_vowel_letter(lower[i])) {
			i++;
			continue;
		}
		size_t j = i;
		while (j < lower.size() && is_vowel_letter(lower[j])) {
			j++;
		}
		if (j < lower.size() && lower[j] == 'r') {
			j++;
		}
		groups.push_back({ lower.substr(i, j - i), i, j });
		i = j;
	}
	std::vector<int> out;
	for (size_t index = 0; index < groups.size(); index++) {
		std::string group = groups[index].text;
		const size_t start = groups[index].start, end = groups[index].end;
		// A silent final "e" is not its own syllable; a leading "y" is a consonant.
		if (group == "e" && start == lower.size() - 1 && index > 0) {
			continue;
		}
		if (start == 0 && group.size() > 1 && group[0] == 'y') {
			group = group.substr(1);
		}
		// Open syllables and vowel-consonant-e ("make", "home") say the letter's long name.
		const bool is_long = end >= lower.size() ||
				(!lower.empty() && lower.back() == 'e' && end == lower.size() - 2 && index < groups.size() - 1);
		out.push_back(group_vowel(group, is_long));
	}
	if (out.empty()) {
		out.push_back(AH);
	}
	if (out.size() > 7) {
		out.resize(7);
	}
	return out;
}

// ---------------------------------------------------------------- line plan

struct Word {
	std::string text;
	double pause = -1.0; // seconds after the word; < 0 = none written
	char end = '.';
	int end_char = 0;
	bool question = false;
	bool final = false;
	bool exclaim = false;
};

bool is_word_char(char32_t c) {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '\'' || c == 0x2019 ||
			(c >= 0xC0 && c != 0xD7 && c != 0xF7 && c < 0x2000);
}

// Words, their pauses and sentence ends, split into breath groups at full stops.
std::vector<std::vector<Word>> plan_line(const String &p_text) {
	std::vector<Word> words;
	std::vector<size_t> sentence;
	const int length = p_text.length();
	for (int i = 0; i < length;) {
		const char32_t c = p_text[i];
		if (is_word_char(c)) {
			int j = i;
			while (j < length && is_word_char(p_text[j])) {
				j++;
			}
			Word w;
			w.text = p_text.substr(i, j - i).utf8().get_data();
			w.end_char = j;
			sentence.push_back(words.size());
			words.push_back(w);
			i = j;
			continue;
		}
		const bool stop = c == '.' || c == '!' || c == '?' || c == '\n';
		const bool soft = c == ',' || c == ';' || c == ':';
		if ((stop || soft) && !words.empty()) {
			words.back().pause = soft ? .16 : .34;
			words.back().end_char = i + 1;
			if (stop) {
				for (size_t index : sentence) {
					words[index].end = c == '\n' ? '.' : char(c);
				}
				sentence.clear();
			}
		}
		i++;
	}
	std::vector<std::vector<Word>> groups;
	std::vector<Word> current;
	for (const Word &w : words) {
		current.push_back(w);
		if (w.pause > .2) {
			groups.push_back(current);
			current.clear();
		}
	}
	if (!current.empty()) {
		groups.push_back(current);
	}
	for (std::vector<Word> &g : groups) {
		for (size_t i = 0; i < g.size(); i++) {
			const bool last = i + 1 == g.size();
			g[i].question = last && g[i].end == '?';
			g[i].final = last && g[i].end == '.';
			g[i].exclaim = g[i].end == '!';
			if (g[i].pause < 0.0) {
				g[i].pause = .055;
			}
		}
	}
	return groups;
}

// Which syllables of a breath group she voices (dev 2026-11-03, Settings > Audio > Ponese
// syllables: fewer sounds for the same words, so lines are shorter and less tiring). Returns, per
// word, the indices of its spelled syllables that are said. At 1.0 every syllable is said. Below
// that the group keeps round(total * fraction) of them, at least one: the group's last syllable
// (its line ending and the close of her melody) and the last syllable before a comma always stay;
// otherwise the inner syllables of long words go first, then word endings, then whole short words
// (their text is shown with the next spoken word), and a syllable next to an already dropped one
// is kept longer so the gaps spread through the group.
std::vector<std::vector<int>> keep_syllables(const std::vector<Word> &p_group, const std::vector<std::vector<int>> &p_spelled, double p_fraction) {
	std::vector<std::vector<int>> kept(p_group.size());
	struct Syllable {
		int word;
		int index;
		double weight;
		bool fixed;
		bool alive;
	};
	std::vector<Syllable> all;
	for (size_t w = 0; w < p_group.size(); w++) {
		const int count = int(p_spelled[w].size());
		int letters = 0;
		for (char c : p_group[w].text) {
			letters += std::isalpha(static_cast<unsigned char>(c)) ? 1 : 0;
		}
		for (int s = 0; s < count; s++) {
			const bool last = s + 1 == count;
			// A word's first syllable carries its stress (longer words more so), its last one the ending.
			const double weight = s == 0 ? 3.0 + .25 * std::min(letters, 8) : (last ? 1.5 : 0.0);
			const bool fixed = last && (w + 1 == p_group.size() || p_group[w].pause > .1);
			all.push_back({ int(w), s, weight, fixed, true });
		}
	}
	const int total = int(all.size());
	const int target = std::max(1, int(std::lround(double(total) * std::clamp(p_fraction, 0.0, 1.0))));
	std::vector<int> alive_in_word(p_group.size(), 0);
	for (const Syllable &s : all) {
		alive_in_word[s.word]++;
	}
	for (int alive = total; alive > target; alive--) {
		int drop = -1;
		double lowest = 1e18;
		for (int i = 0; i < total; i++) {
			const Syllable &s = all[i];
			if (!s.alive || s.fixed) {
				continue;
			}
			double score = s.weight + (alive_in_word[s.word] == 1 ? 1.0 : 0.0);
			score += (i > 0 && !all[i - 1].alive) ? 1.0 : 0.0;
			score += (i + 1 < total && !all[i + 1].alive) ? 1.0 : 0.0;
			if (score < lowest) {
				lowest = score;
				drop = i;
			}
		}
		if (drop < 0) {
			break;
		}
		all[drop].alive = false;
		alive_in_word[all[drop].word]--;
	}
	for (const Syllable &s : all) {
		if (s.alive) {
			kept[s.word].push_back(s.index);
		}
	}
	return kept;
}

// ---------------------------------------------------------------- signal helpers

std::vector<float> resample(const std::vector<float> &p_y, double p_ratio) {
	if (std::abs(p_ratio - 1.0) < 1e-3 || p_y.size() < 2) {
		return p_y;
	}
	const size_t n = std::max<size_t>(2, size_t(double(p_y.size()) / p_ratio));
	std::vector<float> out(n);
	const double step = double(p_y.size() - 1) / double(n - 1);
	for (size_t i = 0; i < n; i++) {
		const double at = i * step;
		const size_t a = std::min(size_t(at), p_y.size() - 2);
		const double t = at - double(a);
		out[i] = float(p_y[a] * (1.0 - t) + p_y[a + 1] * t);
	}
	return out;
}

// Long syllables end early with a soft fade (cos^2), so words keep a talking pace.
void cap(std::vector<float> &p_y, double p_seconds, double p_fade) {
	const size_t n = size_t(RATE * p_seconds);
	if (p_y.size() <= n) {
		return;
	}
	p_y.resize(n);
	const size_t k = std::min(n / 2, size_t(RATE * p_fade));
	for (size_t i = 0; i < k; i++) {
		const double c = std::cos(double(i) / double(std::max<size_t>(1, k - 1)) * PI / 2.0);
		p_y[n - k + i] *= float(c * c);
	}
}

// mercmix joinMatched: slide the next piece up to 4 ms to where its waveform best matches the end
// of the line so far, then blend over `ms` (linear when well matched, equal-power if not).
void join_matched(std::vector<float> &p_out, const std::vector<float> &p_next, double p_ms, std::vector<size_t> *p_starts) {
	const int F = int(RATE * p_ms / 1000.0), SLIDE = int(RATE * .004);
	if (p_out.empty()) {
		if (p_starts) {
			p_starts->push_back(0);
		}
		p_out = p_next;
		return;
	}
	const int n = std::min<int>(F, std::min<int>(int(p_out.size()), int(p_next.size()) - SLIDE));
	if (n < 32) {
		if (p_starts) {
			p_starts->push_back(p_out.size());
		}
		p_out.insert(p_out.end(), p_next.begin(), p_next.end());
		return;
	}
	const float *tail = p_out.data() + p_out.size() - n;
	double tail_energy = 0.0;
	for (int i = 0; i < n; i++) {
		tail_energy += double(tail[i]) * tail[i];
	}
	int best = 0;
	double best_r = -2.0;
	for (int shift = 0; shift <= SLIDE; shift += 2) {
		double dot = 0.0, energy = 0.0;
		for (int i = 0; i < n; i++) {
			const double b = p_next[shift + i];
			dot += tail[i] * b;
			energy += b * b;
		}
		const double norm = std::sqrt(tail_energy * energy);
		const double r = dot / (norm > 0.0 ? norm : 1.0);
		if (r > best_r) {
			best = shift;
			best_r = r;
		}
	}
	const size_t base = p_out.size() - n;
	for (int i = 0; i < n; i++) {
		const double t = (i + .5) / n;
		const double wa = best_r > .5 ? 1.0 - t : std::cos(t * PI / 2.0);
		const double wb = best_r > .5 ? t : std::sin(t * PI / 2.0);
		p_out[base + i] = float(p_out[base + i] * wa + p_next[best + i] * wb);
	}
	if (p_starts) {
		p_starts->push_back(base);
	}
	p_out.insert(p_out.end(), p_next.begin() + best + n, p_next.end());
}

struct Biquad {
	double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
	double z1 = 0, z2 = 0;
	double run(double x) {
		const double y = b0 * x + z1;
		z1 = b1 * x - a1 * y + z2;
		z2 = b2 * x - a2 * y;
		return y;
	}
};

Biquad normalised(double b0, double b1, double b2, double a0, double a1, double a2) {
	Biquad q;
	q.b0 = b0 / a0;
	q.b1 = b1 / a0;
	q.b2 = b2 / a0;
	q.a1 = a1 / a0;
	q.a2 = a2 / a0;
	return q;
}

// RBJ cookbook filters; a 2nd-order Butterworth is the low/high pass with Q = 1/sqrt(2).
Biquad pass(bool p_high, double p_f, double p_q) {
	const double w = 2.0 * PI * std::min(p_f, RATE * .49) / RATE, cw = std::cos(w), alpha = std::sin(w) / (2.0 * p_q);
	if (p_high) {
		return normalised((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + alpha, -2 * cw, 1 - alpha);
	}
	return normalised((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + alpha, -2 * cw, 1 - alpha);
}

Biquad peak(double p_f, double p_db, double p_q) {
	const double a = std::pow(10.0, p_db / 40.0), w = 2.0 * PI * std::min(p_f, RATE * .49) / RATE;
	const double cw = std::cos(w), alpha = std::sin(w) / (2.0 * p_q);
	return normalised(1 + alpha * a, -2 * cw, 1 - alpha * a, 1 + alpha / a, -2 * cw, 1 - alpha / a);
}

Biquad high_shelf(double p_f, double p_db, double p_q) {
	const double a = std::pow(10.0, p_db / 40.0), w = 2.0 * PI * p_f / RATE;
	const double cw = std::cos(w), alpha = std::sin(w) / (2.0 * p_q), sq = 2.0 * std::sqrt(a) * alpha;
	return normalised(a * ((a + 1) + (a - 1) * cw + sq), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - sq),
			(a + 1) - (a - 1) * cw + sq, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - sq);
}

void fft(std::vector<std::complex<double>> &p_a, bool p_inverse) {
	const size_t n = p_a.size();
	for (size_t i = 1, j = 0; i < n; i++) {
		size_t bit = n >> 1;
		for (; j & bit; bit >>= 1) {
			j ^= bit;
		}
		j ^= bit;
		if (i < j) {
			std::swap(p_a[i], p_a[j]);
		}
	}
	for (size_t len = 2; len <= n; len <<= 1) {
		const double angle = 2.0 * PI / double(len) * (p_inverse ? 1.0 : -1.0);
		const std::complex<double> wl(std::cos(angle), std::sin(angle));
		for (size_t i = 0; i < n; i += len) {
			std::complex<double> w(1.0, 0.0);
			for (size_t j = 0; j < len / 2; j++) {
				const std::complex<double> u = p_a[i + j], v = p_a[i + j + len / 2] * w;
				p_a[i + j] = u + v;
				p_a[i + j + len / 2] = u - v;
				w *= wl;
			}
		}
	}
	if (p_inverse) {
		for (std::complex<double> &x : p_a) {
			x /= double(n);
		}
	}
}

// The small dark room: decaying noise, 12 ms pre-delay, 0.35 s, low-passed at 4 kHz, unit energy.
const std::vector<double> &room_response() {
	static const std::vector<double> ir = [] {
		const int n = int(RATE * .35), delay = int(RATE * .012);
		std::vector<double> out(delay + n, 0.0);
		uint64_t state = 7;
		auto uniform = [&state]() {
			state = state * 6364136223846793005ull + 1442695040888963407ull;
			return (double((state >> 11) & ((1ull << 53) - 1)) + .5) / double(1ull << 53);
		};
		Biquad lp = pass(false, 4000.0, 1.0 / std::sqrt(2.0));
		double energy = 0.0;
		for (int i = 0; i < n; i++) {
			const double g = std::sqrt(-2.0 * std::log(uniform())) * std::cos(2.0 * PI * uniform());
			const double v = lp.run(g * std::exp(-double(i) / (RATE * .07)));
			out[delay + i] = v;
			energy += v * v;
		}
		const double norm = 1.0 / std::sqrt(std::max(energy, 1e-12));
		for (double &v : out) {
			v *= norm;
		}
		return out;
	}();
	return ir;
}

// A9 soft chain: darker EQ, de-ess, a gentle compressor that rounds syllable attacks and a short
// dark room (7 % wet) that glues the seams. `p_med` is her usual pitch.
void soften(std::vector<double> &y, double p_med) {
	std::vector<Biquad> chain = { pass(true, std::max(60.0, .5 * p_med), 1.0 / std::sqrt(2.0)), peak(1.6 * p_med, 1.0, .8),
		peak(1000.0, -3.0, 1.2), peak(3000.0, -5.0, .9), high_shelf(5000.0, -8.0, .7), pass(false, 9500.0, 1.0 / std::sqrt(2.0)) };
	for (double &x : y) {
		for (Biquad &q : chain) {
			x = q.run(x);
		}
	}
	const size_t n = y.size();
	// De-ess: the band above 4.5 kHz (4th-order Butterworth) is held under 0.28x the line's level.
	std::vector<double> hi(n);
	Biquad h1 = pass(true, 4500.0, .5411961), h2 = pass(true, 4500.0, 1.3065630);
	for (size_t i = 0; i < n; i++) {
		hi[i] = h2.run(h1.run(y[i]));
	}
	double sum = 0.0;
	size_t active = 0;
	for (double x : y) {
		if (std::abs(x) > 1e-4) {
			sum += x * x;
			active++;
		}
	}
	const double rms = active ? std::sqrt(sum / double(active)) : 1.0;
	const int win = int(RATE * .005);
	std::vector<double> prefix(n + 1, 0.0);
	for (size_t i = 0; i < n; i++) {
		prefix[i + 1] = prefix[i] + hi[i] * hi[i];
	}
	for (size_t i = 0; i < n; i++) {
		// numpy convolve 'same' with a window of `win`: samples i - win/2 .. i + (win - 1)/2 ... centred.
		const long a = long(i) - win / 2, b = a + win;
		const double s = prefix[size_t(std::clamp<long>(b, 0, long(n)))] - prefix[size_t(std::clamp<long>(a, 0, long(n)))];
		const double env = std::sqrt(std::max(s, 0.0) / win) + 1e-9;
		y[i] = (y[i] - hi[i]) + hi[i] * std::min(1.0, .28 * rms / env);
	}
	// Compressor: 2 ms attack, 60 ms release, 2.5:1 above 1.4x the line's level.
	const double att = std::exp(-1.0 / (RATE * .002)), rel = std::exp(-1.0 / (RATE * .06)), thr = 1.4 * rms;
	double e = 0.0;
	for (double &x : y) {
		const double level = std::abs(x);
		e = level > e ? att * e + (1 - att) * level : rel * e + (1 - rel) * level;
		if (e > thr) {
			x *= std::pow(e / thr, 1.0 / 2.5 - 1.0);
		}
	}
	// Room, by FFT convolution.
	const std::vector<double> &ir = room_response();
	size_t size = 1;
	while (size < n + ir.size()) {
		size <<= 1;
	}
	std::vector<std::complex<double>> a(size), b(size);
	for (size_t i = 0; i < n; i++) {
		a[i] = y[i];
	}
	for (size_t i = 0; i < ir.size(); i++) {
		b[i] = ir[i];
	}
	fft(a, false);
	fft(b, false);
	for (size_t i = 0; i < size; i++) {
		a[i] *= b[i];
	}
	fft(a, true);
	double dry = 0.0, wet = 0.0;
	for (size_t i = 0; i < n; i++) {
		dry += y[i] * y[i];
		wet += a[i].real() * a[i].real();
	}
	const double mix = .07 * std::sqrt(dry / std::max(wet, 1e-18));
	for (size_t i = 0; i < n; i++) {
		y[i] += mix * a[i].real();
	}
}

void append_cue(Array &p_cues, double p_start, double p_end, const char *p_value) {
	Dictionary cue;
	cue["start"] = p_start;
	cue["end"] = p_end;
	cue["value"] = String(p_value);
	p_cues.append(cue);
}

} // namespace

// ---------------------------------------------------------------- bank

bool PonyPoneseVoice::load_bank(const PackedByteArray &p_bytes, int p_fft_size) {
	std::lock_guard<std::mutex> lock(cache_mutex);
	cache.clear();
	units.clear();
	phrases.clear();
	rows.clear();
	by_vowel.assign(VOWELS, {});
	const int64_t size = p_bytes.size();
	if (size < 8 || p_fft_size < 64) {
		return false;
	}
	const uint8_t *data = p_bytes.ptr();
	if (std::memcmp(data, "PNV3", 4) != 0) {
		return false;
	}
	const uint32_t header_size = uint32_t(data[4]) | (uint32_t(data[5]) << 8) | (uint32_t(data[6]) << 16) | (uint32_t(data[7]) << 24);
	if (int64_t(header_size) + 8 > size) {
		return false;
	}
	const Variant parsed = JSON::parse_string(String::utf8(reinterpret_cast<const char *>(data + 8), header_size));
	if (parsed.get_type() != Variant::DICTIONARY) {
		return false;
	}
	const Dictionary head = parsed;
	fft_size = p_fft_size;
	dims = int(head.get("dims", 0));
	aperiodicities = int(head.get("aperiodicities", 0));
	f0_loud = double(head.get("f0", 220.0));
	const Array lo_list = head.get("lo", Array()), scale_list = head.get("scale", Array());
	row_size = 2 + dims + aperiodicities;
	if (dims < 8 || aperiodicities < 1 || lo_list.size() != dims + aperiodicities || scale_list.size() != lo_list.size()) {
		return false;
	}
	lo.resize(lo_list.size());
	scale.resize(scale_list.size());
	for (int i = 0; i < lo_list.size(); i++) {
		lo[i] = double(lo_list[i]);
		scale[i] = double(scale_list[i]);
	}
	const int64_t body = size - 8 - int64_t(header_size);
	if (body % row_size != 0) {
		return false;
	}
	const int frame_count = int(body / row_size);
	rows.assign(data + 8 + header_size, data + size);
	const Array unit_list = head.get("units", Array());
	for (int i = 0; i < unit_list.size(); i++) {
		const Array u = unit_list[i];
		if (u.size() < 13) {
			return false;
		}
		Unit unit;
		unit.vowel = int(u[0]);
		unit.start = int(u[1]);
		unit.count = int(u[2]);
		unit.mean = double(u[3]);
		unit.gain = double(u[4]);
		unit.f0s = double(u[5]);
		unit.f0e = double(u[6]);
		unit.dbs = double(u[7]);
		unit.dbe = double(u[8]);
		unit.reg = int(u[9]);
		unit.flags = int(u[10]);
		const String onset = u[11];
		unit.onset = onset.is_empty() ? 0 : onset[0];
		unit.score = double(u[12]);
		if (unit.vowel < 0 || unit.vowel >= VOWELS || unit.count < 4 || unit.start < 0 || unit.start + unit.count > frame_count ||
				unit.mean <= 0.0) {
			return false;
		}
		by_vowel[unit.vowel].push_back(int(units.size()));
		units.push_back(unit);
	}
	const Array phrase_list = head.get("phrases", Array());
	for (int i = 0; i < phrase_list.size(); i++) {
		const Array ph = phrase_list[i];
		std::vector<TemplateWord> words;
		for (int j = 0; j < ph.size(); j++) {
			const Array w = ph[j];
			if (w.size() >= 4) {
				words.push_back({ double(w[0]), double(w[1]), double(w[2]), double(w[3]) });
			}
		}
		if (!words.empty()) {
			phrases.push_back(words);
		}
	}
	if (phrases.empty()) {
		phrases.push_back({ TemplateWord() });
	}
	return !units.empty();
}

void PonyPoneseVoice::set_shape(double p_pitch, double p_formant) {
	std::lock_guard<std::mutex> lock(cache_mutex);
	pitch = std::clamp(p_pitch, .5, 2.0);
	formant = std::clamp(p_formant, .8, 1.25);
	cache.clear();
}

int PonyPoneseVoice::get_unit_count() const {
	return int(units.size());
}

double PonyPoneseVoice::get_f0() const {
	return f0_loud * pitch;
}

// One syllable through the WORLD vocoder at this voice's pitch and formant, levelled (rms 0.1,
// peaks at most 0.9). Cached per syllable.
const std::vector<float> &PonyPoneseVoice::unit_wave(int p_index) const {
	std::lock_guard<std::mutex> lock(cache_mutex);
	auto found = cache.find(p_index);
	if (found != cache.end()) {
		return found->second;
	}
	const Unit &u = units[p_index];
	const int n = u.count, bins = fft_size / 2 + 1;
	std::vector<double> f0(n), coded_sp(size_t(n) * dims), coded_ap(size_t(n) * aperiodicities);
	std::vector<double *> sp_rows(n), ap_rows(n), csp_rows(n), cap_rows(n);
	std::vector<double> sp(size_t(n) * bins), ap(size_t(n) * bins);
	for (int i = 0; i < n; i++) {
		const uint8_t *row = rows.data() + size_t(u.start + i) * row_size;
		f0[i] = double(uint16_t(row[0] | (row[1] << 8))) / 8.0 * pitch;
		for (int d = 0; d < dims; d++) {
			coded_sp[size_t(i) * dims + d] = row[2 + d] * scale[d] + lo[d];
		}
		for (int d = 0; d < aperiodicities; d++) {
			coded_ap[size_t(i) * aperiodicities + d] = row[2 + dims + d] * scale[dims + d] + lo[dims + d];
		}
		csp_rows[i] = coded_sp.data() + size_t(i) * dims;
		cap_rows[i] = coded_ap.data() + size_t(i) * aperiodicities;
		sp_rows[i] = sp.data() + size_t(i) * bins;
		ap_rows[i] = ap.data() + size_t(i) * bins;
	}
	DecodeSpectralEnvelope(csp_rows.data(), n, RATE, fft_size, dims, sp_rows.data());
	DecodeAperiodicity(cap_rows.data(), n, RATE, fft_size, ap_rows.data());
	if (std::abs(formant - 1.0) > 1e-3) {
		std::vector<double> warped(bins);
		for (int i = 0; i < n; i++) {
			double *s = sp_rows[i];
			for (int k = 0; k < bins; k++) {
				const double at = std::min(double(k) / formant, double(bins - 1));
				const int a = std::min(int(at), bins - 2);
				warped[k] = s[a] + (s[a + 1] - s[a]) * (at - a);
			}
			std::copy(warped.begin(), warped.end(), s);
		}
	}
	const int length = int((n - 1) * FRAME_MS / 1000.0 * RATE) + 1;
	std::vector<double> y(length, 0.0);
	Synthesis(f0.data(), n, sp_rows.data(), ap_rows.data(), fft_size, FRAME_MS, RATE, length, y.data());
	double energy = 0.0, top = 0.0;
	for (double v : y) {
		energy += v * v;
		top = std::max(top, std::abs(v));
	}
	const double g = std::min(.1 / std::max(std::sqrt(energy / std::max(1, length)), 1e-6), .9 / std::max(top, 1e-6));
	std::vector<float> wave(length);
	for (int i = 0; i < length; i++) {
		wave[i] = float(y[i] * g);
	}
	return cache.emplace(p_index, std::move(wave)).first->second;
}

// ---------------------------------------------------------------- compose

Dictionary PonyPoneseVoice::compose(const String &p_text, const Dictionary &p_options) const {
	const uint64_t started = Time::get_singleton()->get_ticks_usec();
	Dictionary result;
	if (units.empty()) {
		result["error"] = "ponese bank not loaded";
		return result;
	}
	const String emotion = String(p_options.get("emotion", "neutral")).to_lower();
	const int variation = int(p_options.get("variation", 0));
	const double pace = std::clamp(double(p_options.get("pace", 1.0)), .6, 1.6);
	// Share of each word's syllables she says (Settings > Audio > Ponese syllables); written pauses
	// shrink with it, by half as much, so commas and full stops still breathe.
	const double syllables = std::clamp(double(p_options.get("syllables", 1.0)), .25, 1.0);
	const double pause_scale = .5 + .5 * syllables;
	const std::vector<std::vector<Word>> groups = plan_line(p_text);
	if (groups.empty()) {
		result["error"] = "empty ponese line";
		return result;
	}
	const std::string line_key = std::string(p_text.utf8().get_data()) + "#" + std::to_string(variation);
	const bool loud_line = emotion == "angry" || emotion == "shouting";
	const bool lively = emotion == "happy" || emotion == "surprised" || emotion == "excited";
	std::vector<float> out(size_t(RATE * .05), 0.0f);
	Array cues, word_cues;
	append_cue(cues, 0.0, double(out.size()) / RATE, "X");
	int spoken = 0;
	double last_start = double(out.size()) / RATE; // where the last said word began
	for (size_t gi = 0; gi < groups.size(); gi++) {
		const std::vector<Word> &g = groups[gi];
		const int n = int(g.size());
		bool exclaim = loud_line;
		for (const Word &w : g) {
			exclaim = exclaim || w.exclaim;
		}
		// One register per breath group: calm takes for plain lines, lively and loud ones allowed
		// when she exclaims.
		const int allowed_max = exclaim ? 2 : 1;
		const int prefer = loud_line ? 2 : ((exclaim || lively) ? 1 : 0);
		// Her melody, pace and loudness from one of her real lines with about as many words.
		std::vector<int> order(phrases.size());
		for (size_t i = 0; i < order.size(); i++) {
			order[i] = int(i);
		}
		std::vector<uint32_t> tie(phrases.size());
		for (size_t i = 0; i < phrases.size(); i++) {
			tie[i] = text_hash(line_key + std::to_string(gi) + "/" + std::to_string(i));
		}
		std::sort(order.begin(), order.end(), [&](int a, int b) {
			const int da = std::abs(int(phrases[a].size()) - n), db = std::abs(int(phrases[b].size()) - n);
			return da != db ? da < db : tie[a] < tie[b];
		});
		const std::vector<TemplateWord> &tpl = phrases[order[text_hash(line_key + std::to_string(gi)) % std::min<size_t>(4, order.size())]];
		const int m = int(tpl.size());
		std::vector<std::vector<int>> spelled(n);
		for (int i = 0; i < n; i++) {
			spelled[i] = spelled_vowels(g[i].text);
		}
		const std::vector<std::vector<int>> kept = keep_syllables(g, spelled, syllables);
		// Words left unsaid at fewer syllables: no sound and no gap of their own; their subtitle
		// words appear between the said words around them.
		std::vector<int> unsaid;
		for (int i = 0; i < n; i++) {
			const Word &w = g[i];
			if (kept[i].empty()) {
				unsaid.push_back(i);
				continue;
			}
			const TemplateWord &tw = tpl[std::lround(double(i) * (m - 1) / std::max(1, n - 1))];
			double factor = std::clamp(1.0 + STYLE * (tw.ratio - 1.0), .85, 1.25);
			if (w.exclaim) {
				factor *= 1.05;
			}
			const double seconds = std::clamp(STYLE * tw.per_syllable + (1.0 - STYLE) * .17, .1, .25) / pace;
			std::vector<int> vowels;
			for (int s : kept[i]) {
				vowels.push_back(spelled[i][s]);
			}
			std::string lower = w.text;
			std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return char(std::tolower(c)); });
			const uint32_t key = text_hash(lower) + uint32_t(variation) * 7919u;
			const bool ending = i == n - 1 && (w.final || w.question || w.exclaim);
			struct Option {
				int unit;
				double cost;
				double ratio;
			};
			std::vector<std::vector<Option>> layers;
			for (size_t si = 0; si < vowels.size(); si++) {
				const double r = factor * (w.question ? 1.0 + .14 * double(si + 1) / double(vowels.size()) : 1.0);
				// Candidates: this vowel, then its neighbours, then any, in an allowed register,
				// from a word-stable offset so the same word keeps much the same sounds.
				std::vector<int> pool;
				std::vector<int> tries = { vowels[si] };
				tries.insert(tries.end(), FALLBACK[vowels[si]].begin(), FALLBACK[vowels[si]].end());
				for (int v = 0; v < VOWELS; v++) {
					tries.push_back(v);
				}
				for (int v : tries) {
					for (int index : by_vowel[v]) {
						if (units[index].reg <= allowed_max) {
							pool.push_back(index);
						}
					}
					if (!pool.empty()) {
						break;
					}
				}
				if (pool.empty()) {
					for (int index = 0; index < int(units.size()); index++) {
						pool.push_back(index);
					}
				}
				// Offset by the spelled position, so a kept syllable sounds as it does at 100 %.
				const size_t offset = (key + uint32_t(kept[i][si]) * 7u) % pool.size();
				std::vector<int> cands;
				for (size_t k = 0; k < std::min<size_t>(CANDIDATES, pool.size()); k++) {
					cands.push_back(pool[(offset + k) % pool.size()]);
				}
				double top = -1e9;
				for (int c : cands) {
					top = std::max(top, units[c].score);
				}
				std::vector<Option> row;
				const bool last = si + 1 == vowels.size();
				for (int c : cands) {
					const Unit &u = units[c];
					double cost = .5 * (top - u.score) + (u.reg != prefer ? .15 : 0.0);
					if (last && !(u.flags & 2)) {
						cost += .35; // the word's last syllable should be a real word ending
					}
					if (ending && last) {
						if (!(u.flags & 1)) {
							cost += .4; // and the line's last one a real line ending
						}
						if (w.question && !(u.flags & 4)) {
							cost += .3;
						}
					}
					// Never lowered: pitch only rises (up to 15 %) or stays; lower notes come from
					// takes she said lower.
					const double want = r * f0_loud / u.mean;
					const double got = std::clamp(want, .97, 1.15);
					cost += .08 * std::abs(12.0 * std::log2(got / want));
					row.push_back({ c, cost, got });
				}
				layers.push_back(row);
			}
			// Viterbi: pitch and loudness should meet at every seam, all in one register.
			auto join_cost = [&](const Option &a, const Option &b) {
				const Unit &x = units[a.unit], &y = units[b.unit];
				const double semis = std::abs(12.0 * std::log2((x.f0e * a.ratio) / std::max(y.f0s * b.ratio, 1.0)));
				const double gx = 20.0 * std::log10(std::pow(std::max(x.gain, 1e-3), STYLE));
				const double gy = 20.0 * std::log10(std::pow(std::max(y.gain, 1e-3), STYLE));
				return .05 * std::min(semis, 12.0) + .03 * std::min(std::abs(x.dbe + gx - y.dbs - gy), 20.0) + (x.reg != y.reg ? .3 : 0.0);
			};
			std::vector<double> cost;
			for (const Option &o : layers[0]) {
				cost.push_back(o.cost);
			}
			std::vector<std::vector<int>> back;
			for (size_t k = 1; k < layers.size(); k++) {
				std::vector<double> now;
				std::vector<int> bp;
				for (const Option &c : layers[k]) {
					int best = 0;
					double best_value = 1e18;
					for (size_t q = 0; q < layers[k - 1].size(); q++) {
						const double value = cost[q] + join_cost(layers[k - 1][q], c);
						if (value < best_value) {
							best_value = value;
							best = int(q);
						}
					}
					now.push_back(best_value + c.cost);
					bp.push_back(best);
				}
				cost = now;
				back.push_back(bp);
			}
			int at = int(std::min_element(cost.begin(), cost.end()) - cost.begin());
			std::vector<Option> pick(layers.size());
			for (int k = int(layers.size()) - 1; k >= 0; k--) {
				pick[k] = layers[k][at];
				if (k > 0) {
					at = back[k - 1][at];
				}
			}
			// The word: unfaded syllables joined in 12 ms matched blends; its last one rings out
			// with its real release and a long soft fade.
			const double fade = ending ? .14 : .08;
			double extra = 0.0;
			std::vector<float> word_audio;
			std::vector<size_t> starts;
			const double loud = std::pow(std::clamp(tw.loud, .6, 1.5), STYLE);
			for (size_t k = 0; k < pick.size(); k++) {
				std::vector<float> y = resample(unit_wave(pick[k].unit), pick[k].ratio);
				if (k + 1 == pick.size()) {
					const size_t plain = std::min(y.size(), size_t(RATE * seconds));
					cap(y, std::max(seconds * 1.8, .2), fade);
					extra = std::max(0.0, double(y.size()) - double(plain)) / RATE;
				} else if (y.size() > size_t(RATE * seconds)) {
					y.resize(size_t(RATE * seconds));
				}
				const float gain = float(std::pow(std::clamp(units[pick[k].unit].gain, .6, 1.5), STYLE) * loud);
				for (float &s : y) {
					s *= gain;
				}
				join_matched(word_audio, y, 12.0, &starts);
			}
			const size_t k_in = std::min(word_audio.size() / 4, size_t(RATE * .006));
			for (size_t s = 0; s < k_in; s++) {
				const double v = std::sin(double(s) / double(std::max<size_t>(1, k_in - 1)) * PI / 2.0);
				word_audio[s] *= float(v * v);
			}
			const size_t base = out.size();
			const double start = double(base) / RATE;
			for (size_t u = 0; u < unsaid.size(); u++) {
				Dictionary skipped;
				skipped["start"] = last_start + (start - last_start) * double(u + 1) / double(unsaid.size() + 1);
				skipped["end_char"] = g[unsaid[u]].end_char;
				word_cues.append(skipped);
			}
			spoken += int(unsaid.size());
			unsaid.clear();
			last_start = start;
			Dictionary word_cue;
			word_cue["start"] = start;
			word_cue["end_char"] = w.end_char;
			word_cues.append(word_cue);
			for (size_t k = 0; k < starts.size(); k++) {
				const size_t end = k + 1 < starts.size() ? starts[k + 1] : word_audio.size();
				append_cue(cues, double(base + starts[k]) / RATE, double(base + end) / RATE, MOUTH[vowels[std::min(k, vowels.size() - 1)]]);
			}
			out.insert(out.end(), word_audio.begin(), word_audio.end());
			spoken++;
			double pause = w.pause > .1 ? w.pause * pause_scale : STYLE * std::clamp(tw.gap, .02, .2) + (1.0 - STYLE) * .055;
			pause = w.pause <= .1 ? std::max(.012, pause - .7 * extra) : std::max(.08, pause - .5 * extra);
			pause /= pace;
			const size_t gap_start = out.size();
			out.resize(out.size() + size_t(RATE * pause), 0.0f);
			append_cue(cues, double(gap_start) / RATE, double(out.size()) / RATE, "X");
			if (out.size() > size_t(RATE * MAX_SECONDS)) {
				break;
			}
		}
		if (out.size() > size_t(RATE * MAX_SECONDS)) {
			break;
		}
	}
	if (spoken == 0) {
		result["error"] = "no spoken words";
		return result;
	}
	std::vector<double> y(out.begin(), out.end());
	soften(y, f0_loud * pitch);
	// Line level: rms 0.08 over the voiced parts, peaks at most 0.9.
	double sum = 0.0, top = 0.0;
	size_t active = 0;
	for (double v : y) {
		if (std::abs(v) > 1e-4) {
			sum += v * v;
			active++;
		}
	}
	double g = active ? .08 / std::max(std::sqrt(sum / double(active)), 1e-6) : 1.0;
	for (double v : y) {
		top = std::max(top, std::abs(v * g));
	}
	if (top > .9) {
		g *= .9 / top;
	}
	g *= double(p_options.get("gain", 1.0));
	PackedByteArray pcm;
	pcm.resize(int64_t(y.size()) * 2);
	uint8_t *bytes = pcm.ptrw();
	for (size_t i = 0; i < y.size(); i++) {
		const int16_t s = int16_t(std::clamp(std::lround(y[i] * g * 32767.0), -32767L, 32767L));
		bytes[i * 2] = uint8_t(s & 0xff);
		bytes[i * 2 + 1] = uint8_t((uint16_t(s) >> 8) & 0xff);
	}
	result["pcm"] = pcm;
	result["rate"] = RATE;
	result["cues"] = cues;
	result["word_cues"] = word_cues;
	result["words"] = spoken;
	result["build_usec"] = int64_t(Time::get_singleton()->get_ticks_usec() - started);
	return result;
}

void PonyPoneseVoice::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_bank", "bytes", "fft_size"), &PonyPoneseVoice::load_bank);
	ClassDB::bind_method(D_METHOD("set_shape", "pitch", "formant"), &PonyPoneseVoice::set_shape);
	ClassDB::bind_method(D_METHOD("get_unit_count"), &PonyPoneseVoice::get_unit_count);
	ClassDB::bind_method(D_METHOD("get_f0"), &PonyPoneseVoice::get_f0);
	ClassDB::bind_method(D_METHOD("compose", "text", "options"), &PonyPoneseVoice::compose);
}

} // namespace godot
