using System;
using System.Diagnostics;
using System.Reflection;

namespace Bon.Integrated
{
	static class Deserialize
	{
		// flag to allow allocation of needed types, otherwise we WANT the classes to allocate their stuff when we call their constructor!!
		// -> theres a problem with this idea... the allocation of the initial object.. is it passed in?
		//    YES!! -> THEY ARE RESPONSIBLE. EVEN IF THE STRUCT DOESNT NEW THE CLASS, WE EITHER GET THE INSTANCE OR IGNORE THE THING!!

		// TODO: to deserialize stringView we probably want to include a callback? it could look up the string and return it, or allocate it somewhere!

		[Inline]
		public static Result<void> Thing<T>(BonReader reader, ref T into)
		{
			if (reader.ReachedEnd())
				into = default;
			else
			{
				var variant = Variant.CreateReference(typeof(T), &into);
				Try!(Value(reader, ref variant));

				if (!reader.ReachedEnd())
					return .Err;
			}
			return .Ok;
		}

		// TODO: frequently checking reader.HasError()!!!!!

		static mixin ParseThing<T>(StringView num) where T : var
		{
			T thing = default;
			if (!(T.Parse(.(&num[0], num.Length)) case .Ok(out thing)))
				return .Err(default); // "failed to parse"
#unwarn
			thing
		}

		static mixin DoInt<T, T2>(StringView numStr) where T2 : var where T : var
		{
			// Not all ints have parse methods (that also filter out letters properly), 
			// so we need to do this, along with range checks!

			T2 num = ParseThing!<T2>(numStr);
#unwarn
			if (num > (T2)T.MaxValue || num < (T2)T.MinValue)
				return .Err(default);
#unwarn
			(T)num
		}

		static mixin Integer(Type type, BonReader reader, ref Variant val)
		{
			let num = reader.Integer();
			if (num.Length == 0)
				return .Err(default); // TODO do better error report! "expected integer number"

			// TODO: make a custom parsing func like uint64 to properly parse hex; then allow hex in reader.Integer()

			switch (type)
			{
			case typeof(int8): *(int8*)val.DataPtr = DoInt!<int8, int64>(num);
			case typeof(int16): *(int16*)val.DataPtr = DoInt!<int16, int64>(num);
			case typeof(int32): *(int32*)val.DataPtr = DoInt!<int32, int64>(num);
			case typeof(int64): *(int64*)val.DataPtr = ParseThing!<int64>(num);
			case typeof(int): *(int*)val.DataPtr = DoInt!<int, int64>(num);

			case typeof(uint8): *(uint8*)val.DataPtr = DoInt!<uint8, uint64>(num);
			case typeof(uint16): *(uint16*)val.DataPtr = DoInt!<uint16, uint64>(num);
			case typeof(uint32): *(uint32*)val.DataPtr = DoInt!<uint32, uint64>(num);
			case typeof(uint64): *(uint64*)val.DataPtr = ParseThing!<uint64>(num);
			case typeof(uint): *(uint*)val.DataPtr = DoInt!<uint, uint64>(num);
			}
		}

		static mixin Float(Type type, BonReader reader, ref Variant val)
		{
			let num = reader.Floating();
			if (num.Length == 0)
				return .Err(default); // "expected floating point number"

			switch (type)
			{
			case typeof(float): *(float*)val.DataPtr = ParseThing!<float>(num);
			case typeof(double): *(double*)val.DataPtr = ParseThing!<double>(num);
			}
		}

		static mixin Char(Type type, BonReader reader, ref Variant val)
		{
			let res = reader.Char();
			if (res case .Err)
				return .Err(default); // "expected floating point number"
			var char = res.Get();

			switch (type)
			{
			case typeof(char8): *(char8*)val.DataPtr = *(char8*)&char;
			case typeof(char16): *(char16*)val.DataPtr = *(char16*)&char;
			case typeof(char32): *(char32*)val.DataPtr = *(char32*)&char;
			}
		}

		static mixin Bool(BonReader reader, ref Variant val)
		{
			let res = reader.Bool();
			if (res case .Err)
				return .Err(default); // "expected boolean"

			*(bool*)val.DataPtr = res.Get();
		}

		public static Result<void> Value(BonReader reader, ref Variant val)
		{
			Type valType = val.VariantType;

			if (valType.IsPrimitive)
			{
				if (valType.IsInteger)
					Integer!(valType, reader, ref val);
				else if (valType.IsFloatingPoint)
					Float!(valType, reader, ref val);
				else if (valType.IsChar)
					Char!(valType, reader, ref val);
				else if (valType == typeof(bool))
					Bool!(reader, ref val);
				else Debug.FatalError(); // Should be unreachable
			}
			else if (valType.IsTypedPrimitive)
			{
				mixin ParseUnderlyingLiteral(ref Variant parseVal)
				{
					if (valType.UnderlyingType.IsInteger)
						Integer!(valType.UnderlyingType, reader, ref parseVal);
					else if (valType.UnderlyingType.IsFloatingPoint)
						Float!(valType.UnderlyingType, reader, ref parseVal);
					else if (valType.UnderlyingType.IsChar)
						Char!(valType.UnderlyingType, reader, ref parseVal);
					else if (valType.UnderlyingType == typeof(bool))
						Bool!(reader, ref parseVal);
					else Debug.FatalError(); // Should be unreachable
				}

				if (valType.IsEnum)
				{
					int64 enumValue = 0;
					repeat
					{
						if (reader.EnumHasNamed())
						{
							let name = reader.EnumName();

							// Find field on enum
							bool found = false;
							for (var field in valType.GetFields())
								if (field.[Friend]mFieldData.mFlags.HasFlag(.EnumCase)
									&& name == field.Name)
								{
									// Add value of enum case to current enum value
									enumValue |= *(int64*)&field.[Friend]mFieldData.[Friend]mData;
									found = true;
									break;
								}

							if (!found)
								return .Err; // "enum case not found"
						}
						else
						{
							int64 literalData = 0;
							var parseVal = Variant.CreateReference(val.VariantType, &literalData);
							ParseUnderlyingLiteral!(ref parseVal);
							enumValue |= literalData;
						}
					}
					while (reader.EnumHasMore());

					// Assign value
					switch (valType.Size)
					{
					case 1: *(uint8*)val.DataPtr = *(uint8*)&enumValue;
					case 2: *(uint16*)val.DataPtr = *(uint16*)&enumValue;
					case 4: *(uint32*)val.DataPtr = *(uint32*)&enumValue;
					case 8: *(uint64*)val.DataPtr = *(uint64*)&enumValue;
					default: Debug.FatalError(); // Should be unreachable
					}
				}
				else ParseUnderlyingLiteral!(ref val);
			}
			else if (valType.IsStruct)
			{
				if (valType == typeof(StringView))
				{

				}
				else if (valType.IsEnum && valType.IsUnion)
				{

				}
				else Struct(reader, ref val);
			}
			else if (valType is SizedArrayType)
			{

			}
			else if (valType.IsObject)
			{
				if (valType == typeof(String))
				{

				}
				else Debug.FatalError(); // TODO
			}
			else if (valType.IsPointer)
			{
				Debug.FatalError(); // TODO
			}
			else Debug.FatalError();

			return .Ok;
		}

		static Result<void> Struct(BonReader reader, ref Variant val)
		{
			let structType = val.VariantType;
			using (let block = reader.ObjectBlock())
			{
				while (block.HasMore())
				{
					let name = reader.Identifier();

					FieldInfo fieldInfo;
					switch (structType.GetField(scope .(name)))
					{
					case .Ok(let field):
						fieldInfo = field;
					case .Err:
						// TODO: proper errors
						return .Err; // Field does not exist
					}

					Variant fieldVal = Variant.CreateReference(fieldInfo.FieldType, ((uint8*)val.DataPtr) + fieldInfo.MemberOffset);

					Try!(Value(reader, ref fieldVal));

					if (block.HasMore())
						reader.EntryEnd();

					if (reader.HadErrors())
						return .Err;
				}
			}

			return .Ok;
		}
	}
}