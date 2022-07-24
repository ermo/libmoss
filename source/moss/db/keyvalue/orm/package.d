/*
 * SPDX-FileCopyrightText: Copyright © 2020-2022 Serpent OS Developers
 *
 * SPDX-License-Identifier: Zlib
 */

/**
 * moss.db.keyvalue.orm
 *
 * Compile time ORM support for moss-db
 *
 * Authors: Copyright © 2020-2022 Serpent OS Developers
 * License: Zlib
 */

module moss.db.keyvalue.orm;

public import moss.db.keyvalue.errors;
public import moss.db.keyvalue.interfaces;
public import moss.db.keyvalue.orm.types;

import std.traits;

/**
 * Create the inital model (primary key buckets etc)
 *
 * Params:
 *      M = Model
 *      tx = Read-write transaction
 * Returns: nullable error
 */
public DatabaseResult createModel(M...)(scope return Transaction tx) @safe
{
    static foreach (modelType; M)
    {
        {
            auto err = tx.createBucketIfNotExists(modelName!modelType)
                .match!((DatabaseError error) => DatabaseResult(error),
                        (Bucket bk) => NoDatabaseError);
            if (!err.isNull)
            {
                return err;
            }
        }
    }

    return NoDatabaseError;
}

/**
 * Save the object in the current transaction
 *
 * TODO: Store indices!
 *
 * Params:
 *      M = Model
 *      obj = Model object
 *      tx = Read-write transaction
 * Returns: A nullable error
 */
public DatabaseResult save(M)(scope return ref M obj, scope return Transaction tx) @safe
        if (isValidModel!M)
{
    auto rowID = rowName(obj);

    /* Ensure the *model bucket* exists */
    immutable auto modelBucket = tx.bucket(modelName!M);
    if (modelBucket.isNull)
    {
        return DatabaseResult(DatabaseError(DatabaseErrorCode.BucketNotFound,
                M.stringof ~ ".save(): Create the model first!"));
    }

    /* Stash in the primary index */
    {
        mixin("auto pkey = obj." ~ getSymbolsByUDA!(M, PrimaryKey)[0].stringof ~ ";");
        auto err = tx.set(modelBucket, pkey.mossEncode, rowID);
        if (!err.isNull)
        {
            return err;
        }
    }

    /**
     * Now save all of the fields
     */
    return tx.createBucketIfNotExists(rowID)
        .match!((DatabaseError err) => DatabaseResult(err), (Bucket itemBucket) {
            /* Encode all the fields */
            static foreach (field; __traits(allMembers, M))
            {
                {
                    immutable auto key = field.mossEncode;
                    immutable auto val = __traits(getMember, obj, field).mossEncode;

                    DatabaseResult err = tx.set(itemBucket, key, val);
                    if (!err.isNull)
                    {
                        return err;
                    }
                }
            }

            return NoDatabaseError;
        });
}

/**
 * Load an object by the primary key
 *
 * Params:
 *      M = model
 *      V = lookup value type
 *      obj = Object in which to load the return value
 *      tx = Transaction
 *      lookup = Primary key to lookup
 * Returns: non null DatabaseResult if we failed to load it.
 */
public DatabaseResult load(M, V)(scope return  out M obj,
        scope const ref Transaction tx, in return V lookup) @safe
        if (isValidModel!M)
{
    obj = M.init;
    import std.conv : to;

    enum searchColumn = getSymbolsByUDA!(M, PrimaryKey)[0].stringof;

    /**
     * Perform lookup by primary key.
     */
    M searchObj;
    mixin("searchObj." ~ searchColumn ~ " = lookup;");
    auto bucketID = rowName(searchObj);
    auto bucket = tx.bucket(bucketID);
    if (bucket.isNull)
    {
        return DatabaseResult(DatabaseError(DatabaseErrorCode.BucketNotFound,
                M.stringof ~ ".load(" ~ searchColumn ~ "): Cannot find " ~ to!string(lookup)));
    }

    static foreach (field; __traits(allMembers, M))
    {
        {
            immutable auto rawData = tx.get(bucket, field.mossEncode);
            if (rawData is null)
            {
                obj = M.init;
                return DatabaseResult(DatabaseError(DatabaseErrorCode.KeyNotFound,
                        M.stringof ~ ".load(" ~ searchColumn ~ "): Key not found: " ~ field.idup));
            }
            mixin("obj." ~ field ~ ".mossDecode(rawData);");
        }
    }

    return NoDatabaseError;
}

@("Basic type testing") @safe unittest
{
    @Model static struct User
    {
        @PrimaryKey int id;
        string username;
    }

    immutable auto one = User(2, "bobby");

    static assert(isValidModel!User, "User should be a valid model");
    static assert(modelName!User == "users", "Invalid model name, got: " ~ modelName!User);
    immutable auto expRow = [46, 117, 115, 101, 114, 46, 0, 0, 0, 0, 2];
    assert(rowName(one) == expRow);
}

@("Basic unit testing..") @safe unittest
{
    import moss.db.keyvalue : Database;

    Database db;
    Database.open("lmdb://ormDB", DatabaseFlags.CreateIfNotExists)
        .match!((d) => db = d, (DatabaseError e) => assert(0, e.message));
    scope (exit)
    {
        db.close();
        import std.file : rmdirRecurse;

        "ormDB".rmdirRecurse();
    }

    @Model static struct Animal
    {
        @PrimaryKey string breed;
        bool mostlyFriendly;
    }

    {
        immutable err = db.update((scope tx) => tx.createModel!Animal());
        assert(err.isNull, err.message);
    }

    /* Try to save a dog. */
    {
        auto dog = Animal("dog", true);
        immutable err = db.update((scope tx) => dog.save(tx));
        assert(err.isNull, err.message);
    }

    /* Load a dog only */
    {
        Animal dog;
        immutable err = db.view((tx) => dog.load(tx, "dog"));
        assert(err.isNull, err.message);
        assert(dog.breed == "dog" && dog.mostlyFriendly, "corrupt puppy");
    }

    /* No chickens! */
    {
        Animal chicken;
        immutable err = db.view((tx) => chicken.load(tx, "chicken"));
        assert(!err.isNull, "look at all those chickens");
    }
}

@("Mock users demo") @safe unittest
{
    import moss.db.keyvalue : Database;
    import std.stdint : uint64_t;

    Database db;
    Database.open("lmdb://ormDB2", DatabaseFlags.CreateIfNotExists)
        .match!((d) => db = d, (DatabaseError e) => assert(0, e.message));
    scope (exit)
    {
        db.close();
        import std.file : rmdirRecurse;

        "ormDB2".rmdirRecurse();
    }

    @Model static struct UserAccount
    {
        @PrimaryKey uint64_t id;
        @Indexed string username;
        //Group[] groups;
    }

    @Model static struct Group
    {
        @PrimaryKey uint64_t id;
        // UserAccount[] users;
    }

    /* Get our model in place */
    {
        immutable err = db.update((scope tx) => tx.createModel!(UserAccount, Group));
        assert(err.isNull, err.message);
    }
}
