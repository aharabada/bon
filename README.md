# bon

Bon is a **serialization library** for the [Beef programming language](https://github.com/beefytech/Beef) and is designed to easily serialize and deserialize beef data structures.

## Basics

Bon is reflection based. (De-) Serialization of a value is done in one call to ``Bon.Serialize`` or ``Bon.Deserialize``.
Any (properly [marked](#type-setup)) structure can be passed into these calls to produce a valid result or, in the case of Deserialization, a precise [error](#errors).

For example, assuming that all types used below use the build settings or the ``[BonTarget]`` attribute to include reflection data for them and all fields set below are public or explicitly included, this structure results in the following serialized bon output.

```bf
let structure = new State() {
        currentMode = .Battle(5),
        gameRules = .FriendlyFire | .RandomDrops,
        playerInfo = new List<PlayerInfo>() {
            .() {
                gold = 231,
                level = 2,
                dead = false
            },
            .() {
                gold = 0,
                level = 1,
                dead = true
            },
            default
        },
        partyName = new String("ChaosCrew")
    };

gBonEnv.serializeFlags |= .Verbose; // Output is formatted for editing & readability
let serialized = Bon.Serialize(structure, .. scope String());
```

Content of ``serialized``:
```
{
    gameRules = .FriendlyFire|.RandomDrops,
    partyName = "ChaosCrew",
    currentMode = .Battle{
        stage = 5
    },
    playerInfo = <3>[
        {
            level = 2,
            gold = 231
        },
        {
            level = 1
            dead = true,
        }
    ]
}
```

The output omits default values by default (the deserializer will try to default unmentioned values accordingly). This, among other behaviors, is configurable just like with the ``.Verbose`` flag set above to produce a formatted and more extensive output. Bon's [configuration](#bon-environment) is contained in a ``BonEnvironment`` object, that is passed into every call. By default, the global environment ``gBonEnv`` is used.

For an extensive overview of bon's capabilities, see [Documentation](#documentation) and [Tests](https://github.com/EinScott/bon/blob/main/Tests/src/Test.bf).

## Documentation

- [Serialization](#serialization)
- [Deserialization](#deserialization)
    - [Nulling references](#nulling-references)
- [Supported types](#supported-types)
    - [Pointers](#pointers)
- [Errors](#errors)
- [Syntax](#syntax)
    - [Comments](#comments)
    - [File-level](#file-level)
    - [Special values](#special-values)
    - [Primitives](#integer-numbers)
    - [Enums](#enums)
    - [Strings](#strings)
    - [Object & Array bodies](#object-bodies)
    - [Enum unions](#enum-unions)
    - [Sub-file strings](#sub-file-strings)
    - [Type markers](#type-markers)
    - [Pairs](#pairs)
    - [(References)](#references)
- [Type setup](#type-setup)
    - [Polymorphism](#polymorphism)
    - [Manual setup](#manual-setup)
- [Bon environment](#bon-environment)
    - [Serialize flags](#serialize-flags)
    - [Deserialize flags](#deserialize-flags)
    - [Allocate handlers](#allocate-handlers)
    - [Type handlers](#type-handlers)
    - [Poly types](#poly-types)
- [Extension](#extension)
- [Integrated usage](#integrated-usage)
- [Preprocessor defines](#preprocessor-defines)

### Serialization

Any properly [set up](#type-setup) (and [supported](#supported-types)) value can be passed into ``Serialize``.

```bf
int i = 15;
Bon.Serialize(i, outStr); // outStr: "15"
```

### Deserialization

Any value passed into ``Deserialize`` will be set to the state defined in the bon string, with a few restrictions. Bon will allocate appropriate instances into empty references but [can not null used references](#nulling-references) unless specifically configured to do so. Ideally, references point to instances of the right type or are cleared beforehand.

```bf
int i = ?;
Try!(Bon.Deserialize(ref i, "15"));

SomeClass c = null;
Try!(Bon.Deserialize(ref c, "{member=120}"));
```

#### Nulling references

By default, bon will not null references (as far as it can know). When getting an error from this, it is recommended that you clear structures manually. If bon is always deserializing into empty structures, this case will never occur. Alternatively, the ``.AllowReferenceNulling`` [serialize flag](#serialize-flags) will make bon blindly null references where necessary. This could be useful if the structure is not responsible for managing the object anyway. In some cases, like re-sizing of collections, unintended nulling of entries when trying to shrink the collection to the defined size, another option would be to set the ``.IgnoreUnmentionedValues`` flag to just keep existing entries.

### Supported types

- Primitives (integers, floats, booleans, characters - and typed primitives)
- Enums & Enum unions
- String & StringView (though StringView requires some [setup](#allocate-handlers))
- List
- Dictionary
- Nullable structs
- Custom structs/classes (if [marked](#type-setup) properly, may be processed through [type handlers](#type-handlers))

#### Pointers

Pointers are not supported. The ``.IgnorePointers`` or ``.IngnoreUnmentionedValues`` [deserialize flags](#deserialize-flags) can be set to make bon ignore those fields (or all unmentioned fields) instead of defaulting/trying to handle them. The field can also be [excluded](#type-setup) by putting ``[BonIgnore]`` on it.

### Errors

Serializing does not produce errors and always outputs a valid bon entry. With ``.Verbose`` configured for serialize in the used [bon environment](#serialize-flags), the serializer might output comments with "warnings", for example when a type doesn't have reflection info.

Deserializing might error when encountering syntax errors or types that are not properly set up for use with bon - in the way that the parsed string demands (for example, polymorphism usage). These are, by default, printed to the console (or debug output for tests). The call returns ``.Err`` after encountering an error.

```
BON ERROR: Unterminated string. (line 1)
>   "eg\"
>       ^

BON ERROR: Integer is out of range. (line 1)
> 299
>   ^
> On type: int8

BON ERROR: Field access not allowed. (line 1)
> {i=5,f=1,str="oh hello",dont=8}
>                              ^
> On type: Bon.Tests.SomeThings

BON ERROR: Cannot handle pointer values. (line 1)
> {}
> ^
> On type: uint8*
```

Printing of errors is disabled in non-DEBUG configurations and can be forced off by [defining](#preprocessor-defines) ``BON_NO_PRINT`` in the workspace settings. Optionally, [defining](#preprocessor-defines) ``BON_PROVIDE_ERROR_MESSAGE`` always makes bon call the ``Bon.onDeserializeError`` event with the error message before returning (in case you want to want to properly report it somehow).

### Syntax

#### Comments

Beef/C style comments are supported. ``//`` single line comments, and ``/* */`` multiline comments (even nested ones).

#### File-level

Every file is a list of values. Most commonly, a file is only made up of one element/value. These elements are independent of each other and are each [serialized](#serialization) or [deserialized](#deserialization) in one call. For example:

```
2,
{
    name = "Gustav",
    profession = .Cook
}
```

Would be serialized in two calls. The first one consumes that element from the resulting ``BonContext`` (which strings can implicitly convert to). This allows for some more loose structures and conditional parsing of files. In this case, we check the file version to decide on the layout to expect.

```bf
int version = ?;
CharacterInfo char = null;
var context = Try!(Bon.Deserialize(ref version, bonString));
if (version == 1)
{
    CharacterInfoLegacy old = null;
    context = Try!(Bon.Deserialize(ref old, context));
    char = old.ToNewFormat(.. new .());
}
else context = Bon.Deserialize(ref char, context);

Debug.Assert(context.GetEntryCount() == 0); // No more entries left in the file
```

Similarly, multiple ``Bon.Serialize(...)`` calls can be performed on the same string to produce a file with multiple entries.

#### Special values

- ``?`` **Irrelevant value**: Means default or ignored value based on [bon environment](#deserialize-flags) configuration. Is only valid in arrays, as otherwise the entry could just be omitted to achieve the same result.
- ``default`` **Zero value** Value is explicitly zero.
- ``null`` **Null reference**: Only valid on reference types.

**Floating pointer numbers**:

Can take on the following shapes:

```
.6,
1.0f,
1.352e-3d
```

#### Integer numbers

Integers are range-checked and can be denoted in decimal, hexadecimal, binary or octal notation. The ``u`` suffix is valid on unsigned numbers, the ``l`` suffix is recognized but ignored.

```
246,
2456u,
-34L,
0xBF43,
0b1011,
0o270
```

#### Floating point numbers

Floating point numbers can be denoted in decimal. The ``f`` and ``d`` suffix is valid but ignored.

```
1,
-1.59f,
.3,
1.57e-3
```

#### Chars

Chars start and end with ``'`` and their contents are size- and range-checked. Escape sequences ``\', \", \\, \0, \a, \b, \f, \n, \r, \t, \v, \xFF, \u{10FFFF}`` are supported (based on the char size).

```
'a',
'\t',
'\x09'
```

#### Enums

Enums can be represented by integer numbers or the type's named cases. Named cases are preceded by a ``.``, multiple cases can be combined with ``|``.

```
24,
.ACase,
.Tree | .Bench | 0b1100,
0xF | 0x80 | .Choice,
.SHIFT | .STRG | 'q' // For char enums, also allow char literals
```

#### Strings

Strings are single-line and start and end with a (non-escaped) ``"``. The ``@`` prefix marks verbatim strings. The escape sequences listed in char are valid in strings as well.

```
"hello!",
"My name is \"Grek\", nice to meet you!",
@"C:\Users\Grek\AppData\Roaming\",
"What's this: \u{30A1}? Don't know..."
```

#### Object bodies

Object bodies are enclosed by object brackets ``{}``. They contain a sequence of ``<fieldIdentifier>=<value>`` entries.

```
{
    dontCareArray = default,
    name = "dave",
    gameEntity = null,
    stats = {
        strength = 17,
        dexterity = 10,
        wisdom = 14,
        charisma = 6
    }
}
```

#### Array bodies

Array bodies are enclosed by array brackets ``[]``. They contain a list of ``<value>`` entries. Array bodies might be preceded by array sizers ``<>``. Array sizers denote the actual length of the array, as default entries at the back of the array might have been omitted, but are otherwise optional. Arrays sizers for fixed-size array sizers can contain ``const`` solely to indicate their fixed nature to the user.

```
[],
[1, 2, 3],
<1>[
    {
        event = .EncounterStart,
        say = "hello there!"
    }
],
<15>[],
<const 8>[
    3,
    2,
    1
]
```

#### Enum unions

Enum unions are denoted as a named case name followed by their payload object body. Case names are preceded by a ``.``.

```
.None{},
.Rect{x=5, y=5, width=20, height=10}
```

#### Sub-file strings

Bon sub-file strings start with ``$`` and are enclosed in array brackets ``[]``. The section inside is extracted as-is and represents an independent bon **file-level** array. The contents of the sub-file are mostly unchecked and not necessarily valid apart from the array bracket structure.

```
{
    packageName = "default",
    importers = [
        {
            name = "image",
            target = "sprites/*",
            configStr = $[
                // The importer's config file. In this case
                // it only has this one entry.
                {
                    compileAtlas = true,
                    atlas = {
                        padding = 2,
                        maxPageSize = 1024
                    }
                }
            ]
        },
        // ...
    ]
}
```

Here, ``importers[0].configStr`` will be equivalent to:

```
{
    compileAtlas = true,
    atlas = {
        padding = 2,
        maxPageSize = 1024
    }
}
```

A structure like that might be used like this:

```bf
PackageConfig config = null;
defer
{
    // Deserialize might fail even before allocating our type
    if (config != null)
        delete config;
}
Try!(Bon.Deserialize(ref config, bonString));

for (let importStatement in config.importers)
{
    let importer = Try!(GetImporterByName(importStatement.name));

    // Each importer has its own config structure, so we
    // just pass the sub-file string in for it to do its thing.
    Try!(importer.Run(importStatement.target, importStatement.configStr));
}
```

The package builder does not know what options the individual importers might take. They simply get a bon string to deserialize into their own config structures. This aims to make more complex setups possible within one coherent looking file under the constraint of single-call deserialization.

#### Type markers

Type markers are enclosed by type brackets ``()``. They contain the full name of a beef type and are a prefix to a value. If the mentioned type is a struct, it must mean that the value is boxed. Type markers are necessary for [polymorphed](#polymorphism) values (especially if the target type is abstract or an interface), optional on reference types if they are of the expected type already, and invalid on value types.

```
(System.Int)357,
(Something.Shape).Circle{
    pos = {
        x = 20,
        y = 50
    },
    radius = 1
},
(Something.AClass){},
(uint8[])<5>[1, 12, 63, 2, 52],
(System.Collections.List<int>)[55555, 6666]
```

#### Pairs

A pair are two values separated by a ``:``. The ``Dictionary`` [type handler](#type-handlers) expresses a dictionary as an array of pairs, for example.

```
[
    .KilledPlayer: "Player was killed",
    .PlayeWon: "You won!"
],
[
    "swamp_enemy": {
        hitPoints = 15,
        meleeDamage = 3,
        meleeInterval = 2f,
    }
]
```

#### References

A references starts with ``&`` and is followed by a string of characters made up of digits, numbers or underscores. References are unused by default but are available for custom [type handlers](#type-handlers) to use.

```
&tree_image,
&0
```

### Type setup

In order to use a type with bon, ``[BonTarget]`` simply needs to be placed on it. By default, only public fields are serialized. Fields with ``[BonIgnore]`` will never (except with ``.IgnoreAttributes``) be serialized and can never be deserialized into. Fields with ``[BonInclude]`` will be treated like other public fields. Forbidden fields cannot be accessed in deserialization.

```bf
[BonTarget]
class State
{
    public GameMode currentMode;
    public GameRules gameRules;

    public List<PlayerInfo> playerInfo ~ if (_ != null) delete _;

    // Will be serialized, although it's not public
    [BonInclude]
    String partyName ~ if (_ != null) delete _;

    // Will not be serialized, although it's public
    [BonIgnore]
    public Scene gameScene;

    // Will not be serialized (unless .IncludeNonPublic is set)
    TimeSpan sessionPlaytime;
}

namespace System
{
    // We can now serialize Version!
    [BonTarget]
    extension Version {}
}
```

#### Polymorphism

Polymorphed values denote their actual type as part of the serialized value in order to be deserialized properly. For this to be possible, bon needs to look up the types by name. So a type that need to be serialized with polymorphism like this must be registered on the used [bon environment](#poly-types) with ``env.RegisterPolyType(typeof(x))`` or by placing ``[BonPolyRegister]`` on the type. The first of the two options is especially useful for boxed struct types, which also need to be registered like this in case they should be serialized.

For example, assuming that ``UIButton`` and ``UITextField`` are registered properly:
```bf
let l = new List<UIElement>() {
    new UIButton() {
        clickable = true
    },
    new UITextField() {
        allowChars = .OnlyNumbers
    }
}
```

Will serialize into:
```
[
    (UILib.UIButton){
        clickable = true
    }
    (UILib.UITextField){
        allowChars = .OnlyNumbers
    }
]
```

#### Manual setup

For bon to use a type, reflection data for them simply needs to be included in the build. That means using ``[BonTarget]`` and ``[BonPolyRegister]`` are merely convenience options. In some situations, using the project's or workspace's build settings to force reflection data might be easier.

### Bon environment

``BonEnvironment`` holds bon's configuration. The output behavior of a ``Bon.Serialize`` or ``Bon.Deserialize`` call is only dependent on the value or bon string as well as the bon environment passed in. By default, the global environment ``gBonEnv`` is used. Newly created environments are independent from the it, but start out with a copy of its state.

Bon doesn't mutate the state of bon environments over the course of serialize or deserialize calls, so using bon with the same environment on multiple threads is possible. But outside code editing a bon environment while a bon call on another thread is using it may lead to undefined behavior.

By default, ``gBonEnv`` contains the built-in [type handlers](#type-handlers). Starting out with an empty global bon environment is possible by [defining](#preprocessor-defines) ``BON_NO_DEFAULT_SETUP``. Types with ``[BonPolyRegister]`` on them are also registered on ``gBonEnv`` (in their static constructor).

See [BonEnvironment](https://github.com/EinScott/bon/blob/main/src/BonEnvironment.bf) for more details.

#### Serialize flags

- **.Default** (0) None of the below flags is set.
- **.IncludeNonPublic** Serialize non-public fields.
- **.IncludeDefault** Serialize default values anyway. Fully prints the entire structure.
- **.IgnoreAttributes** Ignore field attributes ``BonInclude`` and ``BonExclude``. Only recommended for debugging / print-only.
- **.Verbose** Output intended for manual editing (or human reading). Will properly format the output, include annotations as comments in special cases (for example: this object body is empty because there is no reflection data for this type), and some things are less compressed for more clarity (like SizedArray const sizer, boolean as "true" or "false", enum as (combination of) cases when possible).

#### Deserialize flags

- **.Default** (0) None of the below flags is set.
- **.IgnoreUnmentionedValues** Values not mentioned (or denoted as irrelevant ``?``) in the bon string will be left as they are. Normally these values are nulled, as a value not being in included in serialization is normally zero, to replicate the exact state defined by the bon string.
- **.IgnorePointers** Pointer values cannot be handled by bon. Setting this makes bon ignore the value instead of erroring. This flag is included in ``.IncludeUnmentionedValues``.
- **.AllowReferenceNulling** Allows bon to null references, in case the an unmentioned value needs to set to default or a reference is occupied but points to an object of the wrong type. By default, bon errors as it avoids possibly leaking objects. See [nulling references](#nulling-references).

#### Allocate handlers

Allocate handlers are intended to give control about the allocation of reference types. By default, bon just allocates new instances where it needs to. These handlers can be registered by type directly, or as an unspeicalized generic type.

```bf
static void MakeString(ValueView refIntoVal)
{
    var str = new String();

    // make stuff with string!

    val.Assign(str);
}

gBonEnv.allocHandlers.Add(typeof(String), new => MakeString);
```

In order to deserialize ``StringView``, a ``stringViewHandler`` needs to be set. It needs to store the string contents somewhere and return a different valid string view to use.

```bf
static StringView HandleStringView(StringView view)
{
    return tempStrings.Add(.. new String(view));
}

gBonEnv.stringViewHandler = new => HandleStringView;
```

#### Type handlers

Type handlers are called as part of the (de-) serialization process. They are responsible for writing a value to a bon string or reconstructing it from one. For example, List and Dictionary support is implemented through type handlers. Handlers can be registered by type or unspecialized generic type if the handler can support any specialized types of it. See [extension](#extension).

#### Poly types

``polyTypes`` is a lookup of type by its name. It's used to enable [polymorphism](#polymorphism). Use ``RegisterPolyType!(type)`` and ``TryGetPolyType(typeName, let type)`` to interact with it.

### Extension

Bon can be extended to support serialization and serialization of certain types through custom methods. The deserialize method should consume whatever the serialize method can emit at the very least. Various pieces of existing functionality in bon can aid in this process, normally hidden in the ``Bon.Integrated`` namespace. See the [Serialize](https://github.com/EinScott/bon/blob/main/src/Serialize.bf) and [Deserialize](https://github.com/EinScott/bon/blob/main/src/Deserialize.bf) classes for exact functionality and available methods. Importantly, the serialize call can not fail, so custom handlers need to either crash entirely or emit a valid value before exiting. At the very least through something like ``{}``, ``[]`` or ``default``.

These methods can also be non-static if bon were to be used very tightly with some system. In this simple example, Resource<> is some wrapper class for centrally managed resources that can be acquired by string, so it makes sense to just serialize that.

```bf
static void ResourceSerialize(BonWriter writer, ValueView val, BonEnvironment env)
{
    let t = (SpecializedGenericType)val.type;
    Debug.Assert(t.UnspecializedType == typeof(Resource<>));

    let name = val.Get<ResourceBase>().resourcePath;
    writer.Reference(name);
}

static Result<void> ResourceDeserialize(BonReader reader, ValueView val, BonEnvironment env)
{
    let t = (SpecializedGenericType)val.type;
    Debug.Assert(t.UnspecializedType == typeof(Resource<>));

    let name = Try!(reader.Reference());

    if (ResourceManager.TryGetResource(name) case .Ok(ResourceBase resource))
    {
        val.Assign(resource);

        return .Ok;
    }
    else Deserialize.Error!("Invalid resource path", reader, t);
}

gBonEnv.typeHandlers.Add(typeof(Resource<>),
    ((.)new => ResourceSerialize, (.)new => ResourceDeserialize));
```

For further reference, see [builtin type handlers](https://github.com/EinScott/bon/blob/main/src/TypeHandlers.bf).

### Integrated usage

Using the ``Bon.Integrated`` namespace, bon methods may be called directly to read *rather* arbitrary structures. It's a similar process to [extending](#extension) bon with a [type handler](#type-handlers) but the process starts with a custom method, instead of a custom method being called by bon.

For example, a method that serializes and deserializes a scene with entity IDs and their components, where a scene is represented as an array block with ``<entityId>:<componentArray>`` pairs that contain ``<type>-<componentBody>`` pairs, which are then handled as normal bon structs.

```bf
// For special usage, a separate env is often nice to have.
BonEnvironment env = new .() ~ delete _;

public void SerializeScene(String buffer)
{
    let writer = scope BonWriter(buffer, env.serializeFlags.HasFlag(.Verbose));
    Serialize.Start(writer);

    using (writer.ArrayBlock())
    {
        EntityId[] ent = null;

        for (let entity in scene.EnumerateEntities())
        {
            SerializeEntity(writer, entity, buffer);
        }
    }

    Serialize.End(writer);
}

void SerializeEntity(BonWriter writer, EntityId e, String buffer)
{
    var e;
    Serialize.Value(writer, ValueView(typeof(EntityId), &e), env);
    writer.Pair();

    using (writer.ArrayBlock())
    {
        for (let entry in scene.GetComponentArrays())
            if (entry.array.GetSerializeData(e, let data))
            {
                // Abuse of type markers to denote type... well it works!
                Serialize.Type(writer, entry.type);
                writer.Pair();
                Serialize.Value(writer, ValueView(entry.type, data.Ptr), env);
            }
    }

    writer.EntryEnd();
}

public Result<void> Deserialize(StringView buffer)
{
    let reader = scope BonReader();
    Try!(reader.Setup(buffer));
    Try!(Deserialize.Start(reader));

    Try!(reader.ArrayBlock());
    while (reader.ArrayHasMore())
    {
        Try!(DeserializeEntity(reader));

        if (reader.ArrayHasMore())
            Try!(reader.EntryEnd());
    }
    Try!(reader.ArrayBlockEnd());
    Try!(Deserialize.End(reader));

    return .Ok;
}

Result<void> DeserializeEntity(BonReader reader)
{
    EntityId e;
    Try!(Deserialize.Value(reader, ValueView(typeof(EntityId), &e), env));

    if (e >= MAX_ENTITIES)
        Deserialize.Error!("EntityId out of range");

    if (scene.CreateSpecificEntitiy(e) case .Err)
        Deserialize.Error!("Requested entity already exists");

    Try!(reader.Pair());

    Try!(reader.ArrayBlock());
    while (reader.ArrayHasMore())
    {
        // Get type from name
        let typeName = Try!(reader.Type());
        if (!env.TryGetPolyType(typeName, let componentType))
            Deserialize.Error!("Failed to find component type in bonEnv.polyTypes");

        let structMemory = scene.ReserveComponent(e, componentType);

        Try!(reader.Pair());
        Try!(Deserialize.Struct(reader, ValueView(componentType, structMemory.Ptr), env));

        if (reader.ArrayHasMore())
            Try!(reader.EntryEnd());
    }
    Try!(reader.ArrayBlockEnd());

    return .Ok;
}
```

### Preprocessor defines

- ``BON_NO_DEFAULT_SETUP`` - The global [bon environment](#bon-environment) is not filled with the builtin [type handlers](#type-handlers) and reflection info need for them is not included either (on List, Dictionary...).
- ``BON_NO_PRINT`` - bon [errors](#errors) are never printed.
- ``BON_PRINT`` - bon [errors](#errors) are always printed (even in non-DEBUG).
- ``BON_PROVIDE_ERROR_MESSAGE`` - bon provides the [error](#errors) messages through the ``Bon.onDeserializeError`` event.

Happy coding!
