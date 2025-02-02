import os


# open target.yaml
with open('target.yaml', 'r') as f:
	# read it as line
	output = []
	lines = f.readlines()
	# iterate each line, and if the first letter is lowercase
	for i in range(len(lines)):
		if lines[i][0].islower():
			# split the line by space 
			words = lines[i].split()
			words[0] = words[0].capitalize()
			words[1] = words[1].capitalize()
			# join the words with space
			converted = ' '.join(words)
			converted += '\n'
			# append the converted line
			output.append(converted)


# open target.yaml
with open('target.yaml', 'w') as f:
	# write the lines
	f.writelines(output)
