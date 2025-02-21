using System;
using System.Collections;
using System.Diagnostics;
using System.Reflection;

namespace Bon.Integrated
{
	static class Serialize
	{
		public static mixin CompNoReflectionError(String type, String example)
		{
			scope:mixin $"No reflection data for {type}!\n(for example: [BonTarget] extension {example} {{}} or through build settings)"
		}

		static mixin DoInclude(ValueView val, BonSerializeFlags flags)
		{
			(flags.HasFlag(.IncludeDefault) || !ValueDataIsZero!(val))
		}

		static mixin DoTypeOneLine(Type type, BonSerializeFlags flags)
		{
			(type.IsPrimitive || (type.IsTypedPrimitive && (!flags.HasFlag(.Verbose) || !type.IsEnum)))
		}

		// These two are for integrated use!
		[Inline]
		public static void Start(BonWriter writer)
		{
			writer.Start();
		}

		[Inline]
		public static void End(BonWriter writer)
		{
			if (writer.outStr.Length == 0)
			{
				// We never explicitly place default automatically to enable DeserializeFlags.IgnoreUnmentionedValues
				// we still need this in order to not shift the file-level "array"
				Irrelevant(writer);
			}

			writer.End();
		}

		public static void Entry(BonWriter writer, ValueView val, BonEnvironment env)
		{
			Start(writer);

			if (DoInclude!(val, env.serializeFlags))
				Value(writer, val, env);
			
			End(writer);
		}

		public static void Value(BonWriter writer, ValueView val, BonEnvironment env, bool doOneLine = false)
		{
			let valType = val.type;

			// Make sure that doOneLineVal is only passed when valid
			Debug.Assert(!doOneLine || DoTypeOneLine!(valType, env.serializeFlags));

			writer.EntryStart(doOneLine);

			if (valType.IsPrimitive)
			{
				if (valType.IsInteger)
					Integer(valType, writer, val);
				else if (valType.IsFloatingPoint)
					Float(valType, writer, val);
				else if (valType.IsChar)
					Char(valType, writer, val);
				else if (valType == typeof(bool))
					Bool(writer, val, env.serializeFlags);
				else Debug.FatalError(); // Should be unreachable
			}
			else if (valType.IsTypedPrimitive)
			{
				// Is used to change what will be printed if the enum has a remainder
				// to be printed as a literal
				int64 enumRemainderVal = 0;
				var printVal = val;

				bool doPrintLiteral = true;
				if (valType.IsEnum && env.serializeFlags.HasFlag(.Verbose))
				{
					doPrintLiteral = false;

					int64 valueData = 0;
					Span<uint8>((uint8*)val.dataPtr, valType.Size).CopyTo(Span<uint8>((uint8*)&valueData, valType.Size));

					bool found = false;
					for (var field in valType.GetFields())
					{
						if (field.[Friend]mFieldData.mFlags.HasFlag(.EnumCase) &&
							*(int64*)&field.[Friend]mFieldData.[Friend]mData == valueData)
						{
							writer.Enum(field.Name);
							found = true;
							break;
						}
					}

					if (!found)
					{
						// There is no exact named value here, but maybe multiple!

						// We only try once, but that's better than none. If you were
						// to have this enum { A = 0b0011, B = 0b0111, C = 0b1100 }
						// and run this on 0b1111, this algorithm would fail to
						// identify .A | .C, but rather .B | 0b1000 because it takes
						// the largest match first and never looks back if it doesn't
						// work out. The easiest way to make something more complicated
						// work would probably be recursion... maybe in the future
						enumRemainderVal = valueData;
						String bestValName = scope .();
						bool foundAny = false;
						while (enumRemainderVal != 0)
						{
							// Go through all values and find best match in therms of bits
							int64 bestVal = 0;
							var bestValBits = 0;
							for (var field in valType.GetFields())
							{
								if (field.[Friend]mFieldData.mFlags.HasFlag(.EnumCase))
								{
									let fieldVal = *(int64*)&field.[Friend]mFieldData.[Friend]mData;

									if (fieldVal == 0 || (fieldVal & ~enumRemainderVal) != 0)
										continue; // fieldVal contains bits that valueLeft doesn't have

									var bits = 0;
									for (let i < sizeof(int64) * 8)
										if (((fieldVal >> i) & 0b1) != 0)
											bits++;

									if (bits > bestValBits)
									{
										bestVal = fieldVal;
										bestValName.Set(field.Name);
										bestValBits = bits;
									}
								}
							}

							if (bestValBits > 0)
							{
								enumRemainderVal &= ~bestVal; // Remove all bits it shares with this
								writer.Enum(bestValName);
								foundAny = true;
							}
							else
							{
								if (foundAny)
									writer.EnumAdd();

								// Print remainder literal
								doPrintLiteral = true;
								printVal = .(val.type, &enumRemainderVal);

								break;
							}

							if (enumRemainderVal == 0)
								break;
						}
					}
				}

				// Print on non-enum types, and if the enum need to append the leftover value as literal
				// or in any case if we're not printing verbose
				if (doPrintLiteral)
				{
					if (valType.UnderlyingType.IsInteger)
						Integer(valType.UnderlyingType, writer, printVal);
					else if (valType.UnderlyingType.IsFloatingPoint)
						Float(valType.UnderlyingType, writer, printVal);
					else if (valType.UnderlyingType.IsChar)
						Char(valType.UnderlyingType, writer, printVal);
					else if (valType.UnderlyingType == typeof(bool))
						Bool(writer, printVal, env.serializeFlags);
					else Debug.FatalError(); // Should be unreachable
				}
			}
			else if (valType.IsStruct)
			{
				if (valType == typeof(StringView))
				{
					let view = *(StringView*)val.dataPtr;

					if (view.Ptr == null)
						writer.Null();
					else writer.String(view);
				}
				else if (valType.IsEnum && valType.IsUnion)
				{
					// Enum union in memory:
					// {<payload>|<discriminator>}

					bool didWrite = false;
					bool foundCase = false;
					uint64 unionCaseIndex = 0;
					uint64 currCaseIndex = 0;
					for (var enumField in valType.GetFields())
					{
						if (enumField.[Friend]mFieldData.mFlags.HasFlag(.EnumDiscriminator))
						{
							let discrType = enumField.FieldType;
							var discrVal = ValueView(discrType, (uint8*)val.dataPtr + enumField.[Friend]mFieldData.mData);
							Debug.Assert(discrType.IsInteger);

							mixin GetVal<T>() where T : var
							{
								T thing = *(T*)discrVal.dataPtr;
								unionCaseIndex = (uint64)thing;
							}

							switch (discrType)
							{
							case typeof(int8): GetVal!<int8>();
							case typeof(int16): GetVal!<int16>();
							case typeof(int32): GetVal!<int32>();
							case typeof(int64): GetVal!<int64>();
							case typeof(int): GetVal!<int>();

							case typeof(uint8): GetVal!<uint8>();
							case typeof(uint16): GetVal!<uint16>();
							case typeof(uint32): GetVal!<uint32>();
							case typeof(uint64): GetVal!<uint64>();
							case typeof(uint): GetVal!<uint>();

							default: Debug.FatalError(); // Should be unreachable
							}

							foundCase = true;
						}
						else if (enumField.[Friend]mFieldData.mFlags.HasFlag(.EnumCase)) // Filter through unioncaseIndex
						{
							Debug.Assert(foundCase);

							// Skip enum cases until we get to the selected one
							if (currCaseIndex != unionCaseIndex)
							{
								currCaseIndex++;
								continue;
							}

							// Do serialize of discriminator and payload
							writer.Enum(enumField.Name);
							Struct(writer, ValueView(enumField.FieldType, val.dataPtr), env);

							didWrite = true;
							break;
						}
					}

					if (!didWrite)
					{
						writer.outStr.Append("default"); // Just like we just do {} on no reflection info structs
						if (env.serializeFlags.HasFlag(.Verbose))
							writer.outStr.Append(scope $"/* No reflection data for {valType}. Add [BonTarget] or force it */");
					}
				}
				else if (GetCustomHandler(valType, env, let func))
					func(writer, val, env);
				else
				{
					if (valType.IsUnion && env.serializeFlags.HasFlag(.Verbose))
						writer.outStr.Append("/* Union struct! fields influence each other */");

					Struct(writer, val, env);
				}
			}
			else if (valType is SizedArrayType)
			{
				let t = (SizedArrayType)valType;
				let count = t.ElementCount;

				// Since this is a fixed-size array, this info is not necessary to
				// deserialize in any case. But it's nice for manual editing to know how
				// much the array can hold
				if (env.serializeFlags.HasFlag(.Verbose))
					writer.Sizer((.)count, true);

				Array(writer, t.UnderlyingType, val.dataPtr, count, env);
			}
			else if (TypeHoldsObject!(valType))
			{
				if (*(void**)val.dataPtr == null)
					writer.Null();
				else
				{
					// We may modify type with polytype for further operations
					var val;

					let polyType = (*(Object*)val.dataPtr).GetType();
					if (polyType != valType)
					{
						Debug.Assert(!polyType.IsObject || polyType.IsSubtypeOf(valType) || (valType.IsInterface && polyType.HasInterface(valType)));

						// Change type of pointer to actual type
						val.type = polyType;

						Type(writer, polyType);
					}
					else Debug.Assert(!valType.IsInterface);

					if (!polyType.IsObject)
					{
						// Throw together the pointer to the box payload
						// in the corlib approved way. (See Variant.CreateFromBoxed)
						let boxType = (*(Object*)val.dataPtr).[Friend]RawGetType();
						let boxedPtr = (uint8*)*(void**)val.dataPtr + boxType.[Friend]mMemberDataOffset;

						Debug.Assert(!polyType.IsObject);

						// polyType already is the type in the box
						Value(writer, ValueView(polyType, boxedPtr), env);

						// Don't call EndEntry twice
						return;
					}
					else if (polyType.IsArray)
					{
						Debug.Assert(polyType != typeof(Array) && polyType is ArrayType);

						let t = polyType as ArrayType;
						
						Debug.Assert(t.GetField("mFirstElement") case .Ok, CompNoReflectionError!("array type", "Array1<T>"));

						let arrType = t.GetGenericArg(0); // T
						var arrPtr = GetValFieldPtr!(val, "mFirstElement"); // T*
						var count = GetValField!<int_arsize>(val, "mLength");
						
						switch (t.UnspecializedType)
						{
						case typeof(Array1<>):
							if (!Serialize.IsArrayFilled(arrType, arrPtr, count, env))
								writer.Sizer((.)count);
							Array(writer, arrType, arrPtr, count, env);

						case typeof(Array2<>):
							let count1 = GetValField!<int_cosize>(val, "mLength1");
							count /= count1;
							writer.MultiSizer((.)count,(.)count1);

							MultiDimensionalArray(writer, arrType, arrPtr, env, count, count1);

						case typeof(Array3<>):
							let count2 = GetValField!<int_cosize>(val, "mLength2");
							let count1 = GetValField!<int_cosize>(val, "mLength1");
							count /= (count1 * count2);
							writer.MultiSizer((.)count,(.)count1,(.)count2);

							MultiDimensionalArray(writer, arrType, arrPtr, env, count, count1, count2);

						case typeof(Array4<>):
							let count1 = GetValField!<int_cosize>(val, "mLength1");
							let count2 = GetValField!<int_cosize>(val, "mLength2");
							let count3 = GetValField!<int_cosize>(val, "mLength3");
							count /= (count1 * count2 * count3);
							writer.MultiSizer((.)count,(.)count1,(.)count2,(.)count3);

							MultiDimensionalArray(writer, arrType, arrPtr, env, count, count1, count2, count3);

						default:
							Debug.FatalError();
						}
					}
					else if (GetCustomHandler(polyType, env, let func))
						func(writer, val, env);
					else Class(writer, val, env);
				}
			}
			else if (valType.IsPointer)
			{
				if (env.serializeFlags.HasFlag(.Verbose))
					writer.outStr.Append("/* Cannot handle pointer values. Put [NoSerialize] on this field */");
			}
			else
			{
				writer.outStr.Append("/* Unhandled. Please report this! */");
				Debug.FatalError();
			}

			writer.EntryEnd(doOneLine);
		}

		static bool GetCustomHandler(Type type, BonEnvironment env, out HandleSerializeFunc func)
		{
			if (env.typeHandlers.TryGetValue(type, let val) && val.serialize != null)
			{
				func = val.serialize;
				return true;
			}
			else if (type is SpecializedGenericType && env.typeHandlers.TryGetValue(((SpecializedGenericType)type).UnspecializedType, let gVal)
				&& gVal.serialize != null)
			{
				func = gVal.serialize;
				return true;
			}
			func = null;
			return false;
		}

		public static void Class(BonWriter writer, ValueView classVal, BonEnvironment env)
		{
			let classType = classVal.type;

			Debug.Assert(classType.IsObject);

			Struct(writer, ValueView(classType, *(void**)classVal.dataPtr), env);
		}

		public static void Struct(BonWriter writer, ValueView structVal, BonEnvironment env)
		{
			let structType = structVal.type;

			bool hasUnnamedMembers = false;
			using (writer.ObjectBlock())
			{
				if (structType.FieldCount > 0)
				{
					for (let m in structType.GetFields(.Instance))
					{
						let flags = env.serializeFlags;
						if ((!flags.HasFlag(.IgnoreAttributes) && m.GetCustomAttribute<BonIgnoreAttribute>() case .Ok) // check hidden
							|| !flags.HasFlag(.IncludeNonPublic) && (m.[Friend]mFieldData.mFlags & .Public == 0) // check protection level
							&& (flags.HasFlag(.IgnoreAttributes) || !(m.GetCustomAttribute<BonIncludeAttribute>() case .Ok))) // check if we still include it anyway
							continue;

						var val = ValueView(m.FieldType, ((uint8*)structVal.dataPtr) + m.MemberOffset);

						if (!DoInclude!(val, flags))
							continue;

						if (flags.HasFlag(.Verbose) && uint64.Parse(m.Name) case .Ok)
							hasUnnamedMembers = true;

						writer.Identifier(m.Name);
						Value(writer, val, env);
					}
				}
			}

			if (env.serializeFlags.HasFlag(.Verbose))
			{
				// Just add this as a comment in case anyone wonders...
				if (!structType is TypeInstance)
					writer.outStr.Append(scope $"/* No reflection data for {structType}. Add [BonTarget] or force it */");
				else if (hasUnnamedMembers)
					writer.outStr.Append("/* Type has unnamed members */");
			}
		}

		public static bool IsArrayFilled(Type arrType, void* arrPtr, int64 count, BonEnvironment env)
		{
			if (DoInclude!(ValueView(arrType, (uint8*)arrPtr + arrType.Stride * (count - 1)), env.serializeFlags))
				return true;
			return false;
		}

		public static void Array(BonWriter writer, Type arrType, void* arrPtr, int64 count, BonEnvironment env)
		{
			let doArrayOneLine = DoTypeOneLine!(arrType, env.serializeFlags);
			using (writer.ArrayBlock(doArrayOneLine))
			{
				if (count > 0)
				{
					var includeCount = count;
					if (!env.serializeFlags.HasFlag(.IncludeDefault)) // DoInclude! would return true on anything anyway
					{
						var ptr = (uint8*)arrPtr + arrType.Stride * (count - 1);
						for (var i = count - 1; i >= 0; i--)
						{
							// If this gets included, we'll have to include everything until here!
							if (DoInclude!(ValueView(arrType, ptr), env.serializeFlags))
							{
								includeCount = i + 1;
								break;
							}

							ptr -= arrType.Stride;
						}
					}

					var ptr = (uint8*)arrPtr;
					for (let i < includeCount)
					{
						var arrVal = ValueView(arrType, ptr);
						if (DoInclude!(arrVal, env.serializeFlags))
							Value(writer, arrVal, env, doArrayOneLine);
						else
						{
							// Shorten this... as mentioned in Entry() we don't automatically place default, but ?
							Irrelevant(writer, doArrayOneLine);
						}

						ptr += arrType.Stride;
					}
				}
			}
		}

		public static void MultiDimensionalArray(BonWriter writer, Type arrType, void* arrPtr, BonEnvironment env, params int64[] counts)
		{
			Debug.Assert(counts.Count > 1); // Must be multi-dimensional!

			let count = counts[0];
			var stride = counts[1];
			if (counts.Count > 2)
				for (let i < counts.Count - 2)
					stride *= counts[i + 2];
			stride *= arrType.Stride;

			using (writer.ArrayBlock())
			{
				if (count > 0)
				{
					var includeCount = count;
					if (!env.serializeFlags.HasFlag(.IncludeDefault))
					{
						var ptr = (uint8*)arrPtr + stride * (count - 1);
						DEFCHECK:for (var i = count - 1; i >= 0; i--)
						{
							// If this gets included, we'll have to include everything until here!
							for (var j < stride)
								if (ptr[j] != 0)
									break DEFCHECK;

							includeCount = i + 1;
							ptr -= stride;
						}
					}

					var ptr = (uint8*)arrPtr;
					for (let i < includeCount)
					{
						bool isZero = true;
						for (var j < stride)
							if (ptr[j] != 0)
							{
								isZero = false;
								break;
							}

						if (!isZero || env.serializeFlags.HasFlag(.IncludeDefault))
						{
							let inner = counts.Count - 1;
							if (inner > 1)
							{
								int64[] innerCounts = scope .[inner];
								for (let j < inner)
									innerCounts[j] = counts[j + 1];

								MultiDimensionalArray(writer, arrType, ptr, env, params innerCounts);
							}
							else Array(writer, arrType, ptr, counts[1], env);

							writer.EntryEnd();
						}	
						else
						{
							// Shorten this... as mentioned in Entry() we don't automatically place default, but ?
							Irrelevant(writer);
						}

						ptr += stride;
					}
				}
			}
		}

		[Inline]
		public static void Type(BonWriter writer, Type type)
		{
			writer.EntryStart();
			writer.Type(type.GetFullName(.. scope .(256)));
		}

		[Inline]
		public static void Irrelevant(BonWriter writer, bool doOneLine = false)
		{
			writer.EntryStart(doOneLine);
			writer.IrrelevantEntry();
			writer.EntryEnd(doOneLine);
		}

		static mixin AsThingToString<T>(BonWriter writer, ValueView val)
		{
			T thing = *(T*)val.dataPtr;
			thing.ToString(writer.outStr);
		}

		[Inline]
		static void Integer(Type type, BonWriter writer, ValueView val)
		{
			switch (type)
			{
			case typeof(int8): AsThingToString!<int8>(writer, val);
			case typeof(int16): AsThingToString!<int16>(writer, val);
			case typeof(int32): AsThingToString!<int32>(writer, val);
			case typeof(int64): AsThingToString!<int64>(writer, val);
			case typeof(int): AsThingToString!<int>(writer, val);

			case typeof(uint8): AsThingToString!<uint8>(writer, val);
			case typeof(uint16): AsThingToString!<uint16>(writer, val);
			case typeof(uint32): AsThingToString!<uint32>(writer, val);
			case typeof(uint64): AsThingToString!<uint64>(writer, val);
			case typeof(uint): AsThingToString!<uint>(writer, val);

			default: Debug.FatalError(); // Should be unreachable
			}
		}

		[Inline]
		static void Char(Type type, BonWriter writer, ValueView val)
		{
			char32 char = 0;
			switch (type)
			{
			case typeof(char8): char = (.)*(char8*)val.dataPtr;
			case typeof(char16): char = (.)*(char16*)val.dataPtr;
			case typeof(char32): char = *(char32*)val.dataPtr;
			}
			writer.Char(char);
		}

		[Inline]
		static void Float(Type type, BonWriter writer, ValueView val)
		{
			switch (type)
			{
			case typeof(float): AsThingToString!<float>(writer, val);
			case typeof(double): AsThingToString!<double>(writer, val);

			default: Debug.FatalError(); // Should be unreachable
			}
		}

		[Inline]
		static void Bool(BonWriter writer, ValueView val, BonSerializeFlags flags)
		{
			bool boolean = *(bool*)val.dataPtr;
			if (flags.HasFlag(.Verbose))
				writer.Bool(boolean);
			else (boolean ? 1 : 0).ToString(writer.outStr);
		}
	}
}