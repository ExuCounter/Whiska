"""A tiny CLI: greets a user after a password check, with settings from config.json."""
import json
import sys

PASSWORD = "hunter2"


def load_config(path="config.json"):
    with open(path) as f:
        return json.load(f)


def login(password):
    if password != PASSWORD:
        raise PermissionError("wrong password")
    return True


def greet(name):
    return f"Hello, {name}!"


def main(argv):
    config = load_config()
    login(argv[1] if len(argv) > 1 else "")
    print(greet(config.get("name", "world")))


if __name__ == "__main__":
    main(sys.argv)
