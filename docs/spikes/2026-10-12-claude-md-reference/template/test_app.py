import unittest

import app


class AppTest(unittest.TestCase):
    def test_greet(self):
        self.assertEqual(app.greet("Ann"), "Hello, Ann!")

    def test_login_rejects_wrong_password(self):
        with self.assertRaises(PermissionError):
            app.login("nope")

    def test_login_accepts_right_password(self):
        self.assertTrue(app.login("hunter2"))
