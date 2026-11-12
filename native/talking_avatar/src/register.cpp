#include "analyzer.h"
#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/class_db.hpp>
using namespace godot;
static void initialize(ModuleInitializationLevel level){if(level==MODULE_INITIALIZATION_LEVEL_SCENE)GDREGISTER_CLASS(TalkingAvatarAnalyzer);}
extern "C" GDExtensionBool GDE_EXPORT talking_avatar_library_init(GDExtensionInterfaceGetProcAddress get_proc,const GDExtensionClassLibraryPtr library,GDExtensionInitialization*init){
    GDExtensionBinding::InitObject binding(get_proc,library,init);binding.register_initializer(initialize);binding.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);return binding.init();
}
