// Ponese v3 voice (2026-11-02, docs/PONESE_V3_2026_11_02.md): plays a pony's gibberish speech
// from her own recorded syllables. A bank (.pnv, tools/ponese/build_ponese_v3.py in the private
// root) stores each syllable as WORLD vocoder frames; this class picks syllables per word (pitch
// and loudness that meet at the seams, one register per line, real word and line endings), makes
// each one with the WORLD vocoder (world_vocoder/, modified BSD), joins them waveform to waveform
// with short phase-matched blends and runs the soft voice chain. It follows the reference player
// tools/ponese/ponese_v3_reference.py ("A9a, no dips, soft") step for step.
//
// load_bank() on any thread; compose() is pure and thread-safe (syllable audio is cached under a
// mutex), so the game calls it on a worker thread.
#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <mutex>
#include <unordered_map>
#include <vector>

namespace godot {

class PonyPoneseVoice : public RefCounted {
	GDCLASS(PonyPoneseVoice, RefCounted)

public:
	struct Unit {
		int vowel = 0;
		int start = 0;
		int count = 0;
		double mean = 0.0;
		double gain = 1.0;
		double f0s = 0.0;
		double f0e = 0.0;
		double dbs = 0.0;
		double dbe = 0.0;
		int reg = 0;
		int flags = 0;
		char32_t onset = 0;
		double score = 0.0;
	};
	struct TemplateWord {
		double ratio = 1.0;
		double per_syllable = .17;
		double loud = 1.0;
		double gap = .05;
	};

private:
	std::vector<uint8_t> rows;
	int dims = 0;
	int aperiodicities = 0;
	int row_size = 0;
	int fft_size = 1024;
	std::vector<double> lo;
	std::vector<double> scale;
	double f0_loud = 220.0;
	std::vector<Unit> units;
	std::vector<std::vector<int>> by_vowel;
	std::vector<std::vector<TemplateWord>> phrases;
	double pitch = 1.0;
	double formant = 1.0;
	mutable std::mutex cache_mutex;
	mutable std::unordered_map<int, std::vector<float>> cache;

	const std::vector<float> &unit_wave(int index) const;

protected:
	static void _bind_methods();

public:
	// Parses a .pnv bank ("PNV3", u32 header length, JSON header, frame rows). False when invalid.
	bool load_bank(const PackedByteArray &p_bytes, int p_fft_size);
	// Voice shape for ponies that share a bank: pitch scales the vocoder's f0 (kept >= 1 so voices
	// are never deepened), formant > 1 moves the vocal tract resonances up (a smaller pony).
	void set_shape(double p_pitch, double p_formant);
	int get_unit_count() const;
	double get_f0() const;
	// {pcm (16-bit mono), rate, cues [{start,end,value}], word_cues [{start,end_char}], words,
	// build_usec}; options: emotion (String), variation (int), pace (float, 1 = her own pace),
	// gain (float), syllables (float .25-1, share of syllables said; 1 = every syllable).
	Dictionary compose(const String &p_text, const Dictionary &p_options) const;
};

} // namespace godot
