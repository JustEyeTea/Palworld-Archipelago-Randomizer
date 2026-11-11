// Calling the game's functions and reading its objects through UE4SS's reflection, shared by the Pal gifts
// (pal_gift.cpp) and the map screen (map_screen.cpp). Seen working in game without crashing; pal_gift.cpp's notes say
// why every call gets its own heap parameter block. Game thread
// only; access violations are not caught (UE4SS ships with SEH off), so everything is checked before a call.
#pragma once

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/String.hpp>
#include <Unreal/NameTypes.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UnrealInitializer.hpp>
#pragma warning(disable : 4005)   // as LuaXDelegateProperty.cpp includes them
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#pragma warning(default : 4005)

namespace ap_reflect
{
    using namespace RC;
    using namespace RC::Unreal;

    // A step that can't go on. Caught at the top and reported as "result: fail <reason>".
    struct Fail
    {
        std::string reason;
    };

    // Game functions run on the game thread only. Lua's key binds and loops call back off it; ExecuteInGameThread is
    // on it. (GetGameThreadId as EventViewerMod/src/Structs.cpp uses it.)
    inline auto on_game_thread() -> bool
    {
        return GetGameThreadId() == std::this_thread::get_id();
    }

    inline auto hex_size(size_t n) -> std::string
    {
        char buf[24]{};
        std::snprintf(buf, sizeof buf, "0x%zx", n);
        return buf;
    }

    inline auto name_of(UObject* obj) -> std::string
    {
        return obj ? to_string(obj->GetName()) : std::string("null");
    }

    inline auto class_of(UObject* obj) -> std::string
    {
        return obj && obj->GetClassPrivate() ? to_string(obj->GetClassPrivate()->GetName()) : std::string("?");
    }

    // A native UFunction by full path. They live all session, so each is looked up once (as LiveView.cpp keeps its
    // StaticFindObject<UFunction*> results in statics).
    inline auto find_function(const CharType* path) -> UFunction*
    {
        static std::unordered_map<StringType, UFunction*> found;
        auto it = found.find(path);
        if (it != found.end()) return it->second;
        auto* fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, path);
        if (!fn) throw Fail{"function not found " + to_string(path)};
        found.emplace(path, fn);
        return fn;
    }

    // The function `path` names as the object's own class has it. A BlueprintImplementableEvent (GetMaxOtomoNum) is an
    // empty native stub on the C++ class with its body in the Blueprint subclass, so called through the C++ class's
    // UFunction it does nothing and returns 0 (seen in game: "party: 0/0", every party gift refused as full).
    // GetFunctionByNameInChain walks from the object's class up, so it finds an override first (UObject.hpp, as
    // GetPropertyByNameInChain below); for a plain native function it finds the same UFunction as the path.
    inline auto resolve(UObject* self, const CharType* path) -> UFunction*
    {
        UFunction* base = find_function(path);
        if (!self) return base;
        const StringType full(path);
        const auto colon = full.rfind(STR(':'));
        if (colon == StringType::npos) return base;
        const StringType short_name = full.substr(colon + 1);
        UFunction* own = self->GetFunctionByNameInChain(FromCharTypePtr<TCHAR>(short_name.c_str()));
        return own ? own : base;
    }

    // One reflected call. The parameter block is heap memory of the function's own size, constructed with
    // InitializeStruct and destroyed with DestroyStruct, so parameters holding strings and arrays (the Pal save data) are
    // built and freed properly; UE4SS's Lua path only zero-fills a stack array and never frees what the game put in it.
    // Same shape as XMulticastDelegateProperty's Broadcast (UE4SS/src/LuaType/LuaXDelegateProperty.cpp).
    class ReflectedCall
    {
      public:
        ReflectedCall(UObject* self, UFunction* fn)
            : m_self(self), m_fn(fn),
              m_size((std::max)({static_cast<size_t>(fn->GetStructureSize()), static_cast<size_t>(fn->GetParmsSize()),
                                 size_t{1}})),
              m_buf(m_size)
        {
            if (!m_self) throw Fail{"no object to call " + name() + " on"};
            // std::vector's block is 16-byte aligned on MSVC x64; nothing in these functions needs more.
            if (m_fn->GetMinAlignment() > 16) throw Fail{name() + ": alignment " + std::to_string(m_fn->GetMinAlignment())};
            m_fn->InitializeStruct(m_buf.data());
        }
        ~ReflectedCall()
        {
            m_fn->DestroyStruct(m_buf.data());
        }
        ReflectedCall(const ReflectedCall&) = delete;
        auto operator=(const ReflectedCall&) -> ReflectedCall& = delete;

        auto name() const -> std::string
        {
            return to_string(m_fn->GetName());
        }
        auto size() const -> size_t
        {
            return m_size;
        }

        // The parameter called `param_name`, checked to lie inside the block (parameters walked as
        // call_ufunction_from_lua walks them, LuaUObject.cpp).
        auto param(const CharType* param_name) -> FProperty*
        {
            for (FProperty* p : TFieldRange<FProperty>(m_fn, EFieldIterationFlags::IncludeDeprecated))
            {
                if (!p->HasAnyPropertyFlags(CPF_Parm) || !(p->GetName() == StringViewType{param_name})) continue;
                const auto offset = p->GetOffset_Internal();
                if (offset < 0 || p->GetSize() <= 0 || static_cast<size_t>(offset) + p->GetSize() > m_size)
                {
                    throw Fail{name() + "." + to_string(param_name) + ": outside the parameter block"};
                }
                return p;
            }
            throw Fail{name() + "." + to_string(param_name) + ": no such parameter"};
        }

        auto ptr(FProperty* p) -> uint8_t*
        {
            return m_buf.data() + p->GetOffset_Internal();
        }

        // A typed pointer to a parameter, only when its size is exactly sizeof(T).
        template <typename T>
        auto at(FProperty* p) -> T*
        {
            if (static_cast<size_t>(p->GetSize()) != sizeof(T))
            {
                throw Fail{name() + "." + to_string(p->GetName()) + ": size " + std::to_string(p->GetSize()) + ", expected " +
                           std::to_string(sizeof(T))};
            }
            return reinterpret_cast<T*>(ptr(p));
        }

        // Bools by their byte offset and masks, as push_boolproperty does (LuaUObject.cpp).
        auto set_bool(FProperty* p, bool value) -> void
        {
            auto* bp = CastField<FBoolProperty>(p);
            if (!bp) throw Fail{name() + "." + to_string(p->GetName()) + ": not a bool"};
            uint8_t* byte = ptr(p) + bp->GetByteOffset();
            *byte = static_cast<uint8_t>((*byte & ~bp->GetFieldMask()) | (value ? bp->GetByteMask() : 0));
        }
        auto get_bool(FProperty* p) -> bool
        {
            auto* bp = CastField<FBoolProperty>(p);
            if (!bp) throw Fail{name() + "." + to_string(p->GetName()) + ": not a bool"};
            return (*(ptr(p) + bp->GetByteOffset()) & bp->GetFieldMask()) != 0;
        }

        auto run() -> void
        {
            m_self->ProcessEvent(m_fn, m_buf.data());
        }

      private:
        UObject* m_self;
        UFunction* m_fn;
        size_t m_size;
        std::vector<uint8_t> m_buf;
    };

    // A member of a struct-typed property, by name, checked to lie inside the struct.
    inline auto member(FProperty* owner, const CharType* member_name) -> FProperty*
    {
        auto* sp = CastField<FStructProperty>(owner);
        if (!sp) throw Fail{to_string(owner->GetName()) + ": not a struct"};
        UScriptStruct* type = sp->GetStruct();
        for (FProperty* p : TFieldRange<FProperty>(type, EFieldIterationFlags::IncludeDeprecated))
        {
            if (!(p->GetName() == StringViewType{member_name})) continue;
            if (p->GetOffset_Internal() < 0 || p->GetOffset_Internal() + p->GetSize() > owner->GetSize())
            {
                throw Fail{to_string(owner->GetName()) + "." + to_string(member_name) + ": outside the struct"};
            }
            return p;
        }
        throw Fail{to_string(owner->GetName()) + "." + to_string(member_name) + ": no such member"};
    }

    // Copies a struct value from one block to another with the destination property's CopyCompleteValue, which deep-copies
    // its strings and arrays, so both blocks can be destroyed on their own (LuaUObject.cpp's push_structproperty copies
    // the same way). A memcpy would leave two owners of the same FStrings and TArrays.
    inline auto copy_struct(FProperty* dst_prop, void* dst, FProperty* src_prop, const void* src) -> void
    {
        auto* d = CastField<FStructProperty>(dst_prop);
        auto* s = CastField<FStructProperty>(src_prop);
        if (!d || !s) throw Fail{"copy " + to_string(src_prop->GetName()) + " -> " + to_string(dst_prop->GetName()) + ": not structs"};
        UScriptStruct* dst_type = d->GetStruct();
        UScriptStruct* src_type = s->GetStruct();
        if (dst_type != src_type)
        {
            throw Fail{"copy " + to_string(src_prop->GetName()) + " -> " + to_string(dst_prop->GetName()) + ": different structs"};
        }
        d->CopyCompleteValue(dst, src);
    }

    // An object property of an object (CharacterContainer, TargetContainer).
    inline auto object_field(UObject* obj, const CharType* field) -> UObject*
    {
        FProperty* p = obj->GetPropertyByNameInChain(FromCharTypePtr<TCHAR>(field));   // as Dumpers.cpp
        if (!p || !p->IsA<FObjectProperty>() || p->GetSize() != sizeof(UObject*))
        {
            throw Fail{class_of(obj) + "." + to_string(field) + ": missing or not an object"};
        }
        return *p->ContainerPtrToValuePtr<UObject*>(obj);
    }

    // obj:fn(arg) for functions that take at most one object and return an object.
    inline auto call_object(UObject* self, const CharType* fn, const CharType* arg_name = nullptr, UObject* arg = nullptr) -> UObject*
    {
        ReflectedCall c(self, resolve(self, fn));
        if (arg_name) *c.at<UObject*>(c.param(arg_name)) = arg;
        c.run();
        return *c.at<UObject*>(c.param(STR("ReturnValue")));
    }

    inline auto call_int(UObject* self, const CharType* fn) -> int32_t
    {
        ReflectedCall c(self, resolve(self, fn));
        c.run();
        return *c.at<int32_t>(c.param(STR("ReturnValue")));
    }
} // namespace ap_reflect
