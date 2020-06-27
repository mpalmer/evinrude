class Range
	def rand
		first + Kernel.rand * (last - first)
	end
end
