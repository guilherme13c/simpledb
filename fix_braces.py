with open("src/server/execution.zig", "r") as f:
    code = f.read()

bad_str = """                                        use_optimized_join = true;
                                    }
                                }
                        }

                        if (!use_optimized_join) {"""

good_str = """                                        use_optimized_join = true;
                                    }
                                }
                            }
                        }

                        if (!use_optimized_join) {"""

code = code.replace(bad_str, good_str)

with open("src/server/execution.zig", "w") as f:
    f.write(code)
