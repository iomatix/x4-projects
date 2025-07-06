import csv

def generate_stubs(csv_path, output_path):
    with open(csv_path, 'r', encoding='utf-8') as f:
        reader = csv.reader(f)
        lines = ["---@diagnostic disable: undefined-global, lowercase-global\n"]
        for row in reader:
            # Znajdujemy funkcję (zwykle 2. kolumna)
            if len(row) >= 2:
                func_name = row[1].strip()
                if func_name:
                    lines.append(f"function {func_name}() end\n")

    with open(output_path, 'w', encoding='utf-8') as out:
        out.writelines(lines)

# Przykład użycia
if __name__ == "__main__":
    generate_stubs("x4_api_stubs_raw.csv", "x4_api_stubs.lua")