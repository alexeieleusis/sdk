// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/object.h"

#include "vm/isolate_reload.h"
#include "vm/resolver.h"
#include "vm/symbols.h"

namespace dart {

#define IRC (Isolate::Current()->reload_context())

void Function::Reparent(const Class& new_cls) const {
  set_owner(new_cls);
}


void Class::Reload(const Class& replacement) {
  // TODO(turnidge): This method is incomplete.
  //
  // CHECKLIST (by field from RawClass);
  //
  // - name_ : DONE, implicitly (needs assert)
  // - functions : DONE
  // - fields : DONE
  // - script : DONE
  // - token_pos : DONE
  // - library : DONE, implicitly (needs assert)
  // - instance_size_in_words : DONE, implicitly (needs assert)
  // - id : DONE, because we are copying into existing class
  // - canonical_types : currently assuming all are of type Type.  Is this ok?
  // - super_type: DONE
  // - constants : DONE, leave these alone.
  // - allocation_stub : DONE for now.  Revisit later.
  //
  // - mixin : todo
  // - functions_hash_table : todo
  // - offset_in_words_to_field : todo
  // - interfaces : todo
  // - type_parameters : todo
  // - signature_function : todo
  // - invocation_dispatcher_cache : todo
  // - direct_subclasses : todo
  // - cha_codes : todo
  // - handle_vtable : todo
  // - type_arguments_field... : todo
  // - next_field_offset... : todo
  // - num_type_arguments : todo
  // - num_own_type_arguments : todo
  // - num_native_fields : todo
  // - state_bits : todo

  // Move all old functions and fields to a patch class so that they
  // still refer to their original script.
  const PatchClass& patch =
      PatchClass::Handle(PatchClass::New(*this, Script::Handle(script())));
  Function& func = Function::Handle();
  Array& funcs = Array::Handle(functions());
  for (intptr_t i = 0; i < funcs.Length(); i++) {
    func = Function::RawCast(funcs.At(i));
    func.set_owner(patch);
  }
  Field& old_field = Field::Handle();
  Array& old_field_list = Array::Handle(fields());
  for (intptr_t i = 0; i < old_field_list.Length(); i++) {
    old_field = Field::RawCast(old_field_list.At(i));
    old_field.set_owner(patch);
  }

  // Replace functions
  funcs = replacement.functions();
  for (intptr_t i = 0; i < funcs.Length(); i++) {
    func ^= funcs.At(i);
    func.Reparent(*this);
  }
  SetFunctions(Array::Handle(replacement.functions()));

  // Replace fields
  Array& field_list = Array::Handle(fields());
  field_list = replacement.fields();
  String& name = String::Handle();
  Field& field = Field::Handle();
  String& old_name = String::Handle();
  Instance& value = Instance::Handle();
  for (intptr_t i = 0; i < field_list.Length(); i++) {
    field = Field::RawCast(field_list.At(i));
    field.set_owner(*this);
    name = field.name();
    if (field.is_static()) {
      // Find the corresponding old field, if it exists, and migrate
      // over the field value.
      for (intptr_t j = 0; j < old_field_list.Length(); j++) {
        old_field = Field::RawCast(old_field_list.At(j));
        old_name = old_field.name();
        if (name.Equals(old_name)) {
          value = old_field.StaticValue();
          field.SetStaticValue(value);
        }
      }
    }
  }
  SetFields(Array::Handle(replacement.fields()));

  // TODO(turnidge): Do we really need to do this here?
  DisableAllocationStub();

  // Replace script
  set_script(Script::Handle(replacement.script()));
  set_token_pos(replacement.token_pos());

  // Update the canonical type(s).
  const Object& types_obj = Object::Handle(replacement.canonical_types());
  Type& type = Type::Handle();
  if (!types_obj.IsNull()) {
    if (types_obj.IsType()) {
      type ^= types_obj.raw();
      type.set_type_class(*this);
    } else {
      const Array& types = Array::Cast(types_obj);
      for (intptr_t i = 0; i < types.Length(); i++) {
        type ^= types.At(i);
        type.set_type_class(*this);
      }
    }
  }

  // Update supertype.
  set_super_type(AbstractType::Handle(replacement.super_type()));
}


bool Class::CanReload(const Class& replacement) {
  if (is_finalized()) {
    const Error& error =
        Error::Handle(replacement.EnsureIsFinalized(Thread::Current()));
    if (!error.IsNull()) {
      IRC->ReportError(error);
      return false;
    }
  }
  // field count check.
  // native field count check.
  // type parameter count check.
  return true;
}


void Library::Reload(const Library& replacement) {
  StorePointer(&raw_ptr()->loaded_scripts_, Array::null());

  const intptr_t kInitialNameCacheSize = 64;
  InitResolvedNamesCache(kInitialNameCacheSize);
  InitClassDictionary();

  // Migrate the dictionary from the replacement library back to the original.
  DictionaryIterator it(replacement);
  Object& entry = Object::Handle();
  Class& cls = Class::Handle();
  String& name = String::Handle();
  while (it.HasNext()) {
    entry = it.GetNext();
    if (entry.IsClass()) {
      cls = IRC->FindOriginalClass(Class::Cast(entry));
      if (cls.IsNull()) {
        // This class is new to the library.
        AddClass(Class::Cast(entry));
      } else {
        // This class was in the library already.
        AddClass(cls);
      }
    } else {
      name = entry.DictionaryName();
      AddObject(entry, name);
    }
  }
}


bool Library::CanReload(const Library& replacement) {
  return true;
}


void ICData::Reset(bool is_static_call) const {
  if (is_static_call) {
    const Function& old_target = Function::Handle(GetTargetAt(0));
    ASSERT(!old_target.IsNull());
    if (!old_target.is_static()) {
      OS::Print("Cannot rebind super-call to %s from %s\n",
                old_target.ToCString(),
                Object::Handle(Owner()).ToCString());
      return;
    }
    const String& selector = String::Handle(old_target.name());
    const Class& cls = Class::Handle(old_target.Owner());
    const Function& new_target =
        Function::Handle(cls.LookupStaticFunction(selector));
    if (new_target.IsNull()) {
      OS::Print("Cannot rebind static call to %s from %s\n",
                old_target.ToCString(),
                Object::Handle(Owner()).ToCString());
      return;
    }
    ResetData();
    AddTarget(new_target);
  } else {
    ResetData();

    // Restore static prediction that + - = have smi receiver and argument.
    // Cf. TwoArgsSmiOpInlineCacheEntry
    if ((NumArgsTested() == 2) /*&& FLAG_two_args_smi_icd*/) {
      const String& selector = String::Handle(target_name());
      if ((selector.raw() == Symbols::Plus().raw()) ||
          (selector.raw() == Symbols::Minus().raw()) ||
          (selector.raw() == Symbols::Equals().raw())) {
        const Class& smi_class = Class::Handle(Smi::Class());
        const Function& smi_op_target = Function::Handle(
            Resolver::ResolveDynamicAnyArgs(smi_class, selector));
        GrowableArray<intptr_t> class_ids(2);
        class_ids.Add(kSmiCid);
        class_ids.Add(kSmiCid);
        AddCheck(class_ids, smi_op_target);
      }
    }
  }
}


}   // namespace dart.