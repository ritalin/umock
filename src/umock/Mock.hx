package umock;

import haxe.rtti.Infos;
import haxe.rtti.CType;

#if neko
import neko.Lib;
#elseif php
import php.Lib;
#end

import haxe.macro.Expr;
import haxe.macro.Context;

import umock.rtti.RttiUtil;

/**
 * Gives typesafe information about fields and methods that can be used in Mock.setup()
 * @author Andreas Soderlund
 * @example mock.setup(The.field(mock.object.a)).returns(123);
 */
class The
{
	@:macro public static function field(e : Expr)
	{
		switch(e.expr)
		{
			case EField(e, f):
				// Return a string to notify Mock.setup() that it's a field.
				return { expr: EConst(CString(f)), pos: Context.currentPos() };
				
			default:
				// If no match, return itself to get intellisense.
				return e;
		}
	}
	
	@:macro public static function method(e : Expr)
	{
		switch(e.expr)
		{
			case EField(e, f):
				// To notify Mock.setup() that this is a method call,
				// return an anonymous method that returns the fieldname as a string.
				var cPos = Context.currentPos();
				return { expr: EFunction( {expr: { expr: EReturn( { expr: EConst(CString(f)), pos : cPos } ), pos : cPos }, args: [], ret: null } ), pos: cPos };
				
			default:
				// If no match, return itself to get intellisense.
				return e;
		}
	}	
}

/**
 * Verifies if a method has been called the correct number of times.
 */
class Times
{
	private var count : Int;
	private var max : Bool;
	private var min : Bool;
	
	public function new(count : Int, ?max : Bool, ?min : Bool)
	{
		this.count = count;
		this.max = max;
		this.min = min;
	}
	
	public static function Once()
	{
		return new Times(1);
	}
	
	public static function Never()
	{
		return new Times(0);
	}

	public static function AtLeastOnce()
	{
		return new Times(1, false, true);
	}

	public static function AtMostOnce()
	{
		return new Times(1, true, false);
	}

	public static function AtLeast(calls : Int)
	{
		return new Times(calls, false, true);
	}

	public static function AtMost(calls : Int)
	{
		return new Times(calls, true, false);
	}

	public static function Exactly(calls : Int)
	{
		return new Times(calls, false, false);
	}

	public function isValid(callCount : Int)
	{
		if (max == true)
			return callCount <= count;
		
		if (min == true)
			return callCount >= count;
			
		return callCount == count;
	}
	
	public function toString()
	{
		if (max == true)
			return "at most " + count + " call" + (count == 1 ? "" : "s");
			
		if (min == true)
			return "at least " + count + " call" + (count == 1 ? "" : "s");
			
		return "exactly " + count + " call" + (count == 1 ? "" : "s");
	}
}

/**
 * The mock object that handles all setup and verification.
 */
class Mock<T>
{	
	public var funcCalls : Hash<Int>;

	private var mockObject : Dynamic;
	public var object(getObject, null) : T;
	private function getObject() : T
	{
		return cast mockObject;
	}

	/**
	 * Instantiates a new mock object
	 * @param	type Class/Interface type for the mock.
	 * @example var mock = new Mock<IPoint>(IPoint);
	 */
	public function new(type : Class<Dynamic>)
	{
		var name = Type.getClassName(type);
		var cls = Type.resolveClass(name);

		if (cls == null)
		{
			// No class defined, make it a mock object.
			//trace(name + " becomes a MockObject");
			mockObject = new MockObject(type);
		}
		else
		{
			// Class exists, make an empty instance to keep methods.
			//trace(name + " becomes an EmptyInstance");
			#if php
			mockObject = new MockObject(type, Type.createEmptyInstance(cls));
			#else
			mockObject = Type.createEmptyInstance(cls);
			#end
		}

		/*
		if (!Std.is(mockObject, MockObject) && Reflect.field(type, "__rtti") != null)
		{
			// If an type implements rtti, test all fields on object. If all fields are null
			// it's probably an interface so then we can create a MockObject to simulate all methods.
			var object = this.mockObject;
			var notNullFields = Lambda.filter(Type.getInstanceFields(type), function(field : String) { return Reflect.field(object, field) != null; } );
			
			if (notNullFields.length == 0)
			{
				trace(Type.getClassName(type) + " is redefined from EmptyInstance to MockObject");
				mockObject = new MockObject(type);
			}
		}
		*/
				
		funcCalls = new Hash<Int>();
	}

	/**
	 * Setup a field (or method) so that it returns a specific value.
	 * @param	field 'String' for setting up a field, 'Void -> String' to setup a method. The method should return the fieldname.
	 * @return  A context object that will be used to define behavior.
	 * @example mock.setup(The.method(mock.object.getDate)).returns(Date.now());
	 */
	public function setup(field : Dynamic) : MockSetupContext<T>
	{
		var fieldName : String;
		var isFunc : Bool = false;
		
		if (Reflect.isFunction(field))
		{
			fieldName = field();
			isFunc = true;
		}
		else if(Std.is(field, String))
			fieldName = field;
		else
			throw "Only 'String' or 'Void -> String' are allowed arguments for setup()";
		
		return new MockSetupContext<T>(this, fieldName, isFunc);
	}
	
	/**
	 * Verifies that a method has been called a specific number of times.
	 * @param	methodName name of method
	 * @param	?times Verification object. Use the static Times class to create constraints.
	 * @example mock.verify(The.method(mock.object.getDate), Times.Once());
	 * @throws  MockException if the verification fails.
	 */
	public function verify(field : Dynamic, ?times : Times)
	{
		var fieldName : String;
		
		if (Reflect.isFunction(field))
			fieldName = field();
		else if(Std.is(field, String))
			fieldName = field;
		else
			throw "Only 'String' or 'Void -> String' are allowed arguments for setup()";
		
		if (times == null)
			times = Times.AtLeastOnce();
		
		var count = funcCalls.exists(fieldName) ? funcCalls.get(fieldName) : 0;
		
		if (!times.isValid(count))
			throw new MockException("Mock verification failed: Expected " + times + " to function " + fieldName + ", but was " + count + " call"  + (count == 1 ? "" : "s") + ".");
	}
	
	private function addCallCount(field : String) : Void
	{
		if (!funcCalls.exists(field))
			funcCalls.set(field, 1);
		else
			funcCalls.set(field, funcCalls.get(field) + 1);
	}	
}

private class MockSetupContext<T>
{
	private var mock : Mock<T>;
	private var fieldName : Dynamic;
	private var isFunc : Bool;
	private var callBacks : Array<Void -> Void>;
	
	public function new(mock : Mock<T>, fieldName : String, isFunc : Bool)
	{
		this.mock = mock;
		this.fieldName = fieldName;
		this.isFunc = isFunc;
		this.callBacks = new Array < Void -> Void > ();
		
		//trace("Context: " + fieldName + "(" + isFunc + ")");
	}
	
	/**
	 * Specifies what value a mocked field should return
	 * @param	value Return value.
	 * @return  The same context object for method chaining.
	 */
	public function returns(value : Dynamic) : MockSetupContext<T>
	{
		var fieldName = this.fieldName;
		var calls = this.callBacks;
		
		if (isFunc)
		{
			//trace("Function: " + fieldName + " on " + mock.object + " should return " + value);
			
			var p : { private function addCallCount(field : String) : Void; } = mock;
			
			var returnFunction = Reflect.makeVarArgs(function(args : Array<Dynamic>) {
				//trace("addCallCount: " + fieldName);
				p.addCallCount(fieldName);
				for (f in calls) f();

				return value;
			});		
			
			Reflect.setField(mock.object, fieldName, returnFunction);
		}
		else
		{
			Reflect.setField(mock.object, fieldName, value);
		}
			
		return this;
	}
	
	/**
	 * Specifies that a field should throw an exception.
	 * @param	value Exception to throw.
	 */
	public function throws(value : Dynamic)
	{
		Reflect.setField(mock.object, fieldName, throw value);
		return this;
	}
	
	/**
	 * A callback method that is executed on field invocation.
	 * @param	f A callback function
	 * @return  The same context object for method chaining.
	 */
	public function callBack(f : Void -> Void) : MockSetupContext<T>
	{
		if (!isFunc)
			throw "Callbacks aren't allowed on fields.";
			
		// If no function is specified, create a default
		if (Reflect.field(mock.object, fieldName) == null)
			returns(null);
		
		callBacks.push(f);
		return this;
	}
}

private class MockObject implements Dynamic
{
	public function new(type : Class<Dynamic>, ?realObject : Dynamic)
	{
		if (realObject != null)
		{
			// A PHP workaround - Methods cannot be redefined on an object so a MockObject has to be created.
			for (field in Type.getInstanceFields(Type.getClass(realObject)))
			{
				Reflect.setField(this, field, Reflect.field(realObject, field));
			}			
		}
		else if (untyped type.__rtti == null)
		{
			for (field in Type.getInstanceFields(type))
			{
				Reflect.setField(this, field, null);
			}
		}
		else
		{
			for (field in RttiUtil.getFields(type))
			{
				switch(field.type)
				{
					case CFunction(args, ret):
						Reflect.setField(this, field.name, Reflect.makeVarArgs(function(a : Array<Dynamic>) {} ));
						
					default:
						Reflect.setField(this, field.name, null);
				}			
			}
		}
	}
}