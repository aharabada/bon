# bon

bon is a **serialization library** for the [Beef programming language](https://github.com/beefytech/Beef) and is designed to easily serialize and deserialize beef data structures.

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

For an extensive overview of bon's capabilites, see [Documentation](#documentation) and [Tests](https://github.com/EinScott/bon/blob/main/Tests/src/Test.bf).

## Documentation

- [Serialization](#serialization)
- [Deserialization](#deserialization)
	- [how to handle reference nulling](#nulling-refrences)
- [Errors](#errors)
- [Syntax](#syntax)
- [Type setup](#type-setup)
	- how to ex-/include fields from being serialized
- [Bon environment](#bon-environment)
	- [how to control the allocation of certain types](#alloc-handlers)
	- [how to serialize polymorphed references](#poly-types)
- [Supported types](#supported-types)
	- [how to make bon ignore pointer values](#pointers)
- [Extension](#extension)
	- how to write custom handlers for certain types
- [Integrated usage](#integrated-usage)
	- how to process arbitrary structures

TODO add links to other sub-categories

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

Set the .AllowReferenceNulling flag if bon can null them without leaking anything, clear them or make bon ignore the field

TODO

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

Printing of errors is disabled in non-DEBUG configurations and can be forced off by defining ``BON_NO_PRINT`` in the workspace settings. Optionally, defining ``BON_PROVIDE_ERROR_MESSAGE`` always makes bon call the ``Bon.onDeserializeError`` event with the error message before returning (in case you want to want to properly report it somehow).

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

#### Chars

Chars start and end with ``'`` and their contents are size- and range-checked. Escape sequences ``\', \", \\, \0, \a, \b, \f, \n, \r, \t, \v, \xFF, \u{10FFFF}`` are supported (based on the char size).

```
'a',
'\t',
'\x09'
```

#### Enums

Enums can be represented by integer numbers or the type's named cases. Named cases are preceeded by a ``.``, multiple cases can be combined with ``|``.

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

Type markers are enclosed by type brackets ``()``. They contain the full name of a beef type and are a prefix to a value. If the mentioned type is a struct, it must mean that the value is boxed. Type markers are necessary for polymorphed values (especially if the target type is abstract or an interface), optional on reference types if they are of the expected type already, and invalid on value types.

For this to work with deserialization, bon needs to look up the types by name. Thus, a type that need to be serialized with polymorphism like this must be registered on the used [bon environment](#poly-types) with ``env.RegisterPolyType(typeof(x))`` or by placing ``[BonPolyRegister]`` on the type.

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

TODO document &(references) and :(pairs)

### Type setup

In order to use a type with bon, ``[BonTarget]`` simply needs to be placed on it. By default, only public fields are serialized. Fields with ``[BonIgnore]`` will never (except with ``.IgnoreAttributes``) be serialized and can never be deserialized into. Fields with ``[BonInclude]`` will be treated like other public fields. Forbidden fields cannot be accessed in deserialization.

```bf
[BonTarget]
class State
{
	public GameMode currentMode;
	public GameRules gameRules;
	
	public List<PlayerInfo> playerInfo ~ if (_ != null) delete _;
	
	// Will be serialized, allthough it's not public
	[BonInclude]
	String partyName ~ if (_ != null) delete _;
	
	// Will not be serialized, allthough it's public
	[BonIgnore]
	public Scene gameScene;
	
	// Will not be serialized (unless .IncludeNonPublic is set)
	TimeSpan sessionPlaytime;
}
```

#### Polymorphism

If the structure you want to serialize polymorphed references to this type, for example as an ``Object``, you also need to place ``[BonPolyRegister]`` on it as well.

TODO: polymorphism handling

#### Manual setup

For bon to use a type, reflection data for them simply needs to be included in the build. Fields may be [marked](#type-setup) to affect bon's behaviour, for example excluding them.

TODO

the attributes BonTarget and BonPolyRegister don't need to be used

how to force reflection data in the IDE...

BonTarget -> just does reflection force for you, can also be done in build settings
BonPolyRegister -> types can also be registered into BonEnv manually by calling RegisterPolyType!(type)

### Bon environment

editing a bon environment while a bon call on another thread is using it may lead to undefined behaviour. apart from that, bon is thread safe.
Newly created environments are independent from the global environment ``gBonEnv``, but start out with a copy of its state.

flags & handlers, how to reset default config

TODO

#### Serialize flags

#### Deserialize flags

#### Alloc handlers

#### Type handlers

#### Poly types

### Supported types

Primitives and strings (as well as [some common corlib types](#supported-types), such as ``List<T>``) are supported by default.

TODO

#### Pointers

Pointers are not supported.

set .IgnorePointer or .IngnoreUnmentioned values to make bon ignore those fields (or all unmentioned fields) instead of defaulting them.

explain + link to #type-setup & #deserialize-flags

### Extension

TODO

basically some pointers on writing handlers
..?
-> serialize can never error. it either must be forced by default by the lib to be always present, or, if info is not provided, a valid "empty" value should be printed, like ``{}`` for objects without reflection info.

example for "&somethingName" handler
-> for example, for types like Asset<> registered, then can retrieve asset with name

### Integrated usage

TODO

integrated serialize / deserialize - demo with scene stuff?
